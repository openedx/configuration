import redis
import json
import datetime
import click
import boto3
import botocore
import backoff
from itertools import zip_longest

MAX_TRIES = 5
QUEUE_AGE_HASH_NAME = "queue_age_monitoring"
DATE_FORMAT = '%Y-%m-%d %H:%M:%S.%f'


class RedisWrapper(object):
    def __init__(self, *args, **kwargs):
        self.redis = redis.StrictRedis(*args, **kwargs)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def keys(self):
        return self.redis.keys()

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def type(self, key):
        return self.redis.type(key)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def llen(self, key):
        return self.redis.llen(key)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def lindex(self, key, index):
        return self.redis.lindex(key, index)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def hgetall(self, key):
        return self.redis.hgetall(key)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def delete(self, key):
        return self.redis.delete(key)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def hset(self, *args):
        return self.redis.hset(*args)

    @backoff.on_exception(backoff.expo,
                          (redis.exceptions.TimeoutError,
                           redis.exceptions.ConnectionError),
                          max_tries=MAX_TRIES)
    def hmset(self, *args):
        return self.redis.hmset(*args)


class CwBotoWrapper(object):
    def __init__(self):
        self.client = boto3.client('cloudwatch')

    @backoff.on_exception(backoff.expo,
                          (botocore.exceptions.ClientError),
                          max_tries=MAX_TRIES)
    def list_metrics(self, *args, **kwargs):
        return self.client.list_metrics(*args, **kwargs)

    @backoff.on_exception(backoff.expo,
                          (botocore.exceptions.ClientError),
                          max_tries=MAX_TRIES)
    def put_metric_data(self, *args, **kwargs):
        #return self.client.put_metric_data(*args, **kwargs)
        return True

    @backoff.on_exception(backoff.expo,
                          (botocore.exceptions.ClientError),
                          max_tries=MAX_TRIES)
    def describe_alarms_for_metric(self, *args, **kwargs):
        return self.client.describe_alarms_for_metric(*args, **kwargs)

    @backoff.on_exception(backoff.expo,
                          (botocore.exceptions.ClientError),
                          max_tries=MAX_TRIES)
    def put_metric_alarm(self, *args, **kwargs):
        #return self.client.put_metric_alarm(*args, **kwargs)
        return True


def datetime_from_str(string):
    return datetime.datetime.strptime(string, DATE_FORMAT)

def str_from_datetime(dt):
    return dt.strftime(DATE_FORMAT)

def unpack_state(packed_state):
    decoded_state = {k.decode("utf-8"): v for k, v in packed_state.items()}
    packed_state = {}

    for key, value in decoded_state.items():
        decoded_value = json.loads(value)
        packed_state[key] = {
            'correlation_id': decoded_value['correlation_id'],
            'first_occurance_time': datetime_from_str(decoded_value['first_occurance_time']),
        } 

    return packed_state

def pack_state(unpacked_state):
    packed_state = {}
    for queue_name, queue_state in unpacked_state.items():
        dt_str = str_from_datetime(queue_state['first_occurance_time'])
        packed_state[queue_name] = json.dumps({
            'correlation_id': queue_state['correlation_id'],
            'first_occurance_time': dt_str,
        })
    return packed_state

def build_new_state(old_state, queue_first_items, current_time):
    new_state = {}
    for queue_name, first_item_encoded in queue_first_items.items():
        # TODO: Catch/Handle exception if not json
        first_item = json.loads(first_item_encoded)
        # TODO: Handle keys missing in data
        correlation_id = first_item['properties']['correlation_id']
        first_occurance_time = current_time

        if queue_name in old_state:
            old_correlation_id = old_state[queue_name]['correlation_id']
            if old_correlation_id == correlation_id:
                first_occurance_time = old_state[queue_name]['first_occurance_time']

        new_state[queue_name] = {
            'correlation_id': correlation_id,
            'first_occurance_time': first_occurance_time,
        }

    return new_state

@click.command()
@click.option('--host', '-h', default='localhost',
              help='Hostname of redis server')
@click.option('--port', '-p', default=6379, help='Port of redis server')
@click.option('--environment', '-e', required=True)
@click.option('--deploy', '-d', required=True,
              help="Deployment (i.e. edx or edge)")
@click.option('--max-metrics', default=20,
              help='Maximum number of CloudWatch metrics to publish')
@click.option('--threshold', default=50,
              help='Default maximum queue length before alarm notification is'
              + ' sent')
@click.option('--queue-threshold', type=(str, int), multiple=True,
              help='Threshold per queue in format --queue-threshold'
              + ' {queue_name} {threshold}. May be used multiple times')
@click.option('--sns-arn', '-s', help='ARN for SNS alert topic', required=True)
def check_queues(host, port, environment, deploy, max_metrics, threshold,
                 queue_threshold, sns_arn):

    thresholds = dict(queue_threshold)

    timeout = 1
    namespace = "celery/{}-{}".format(environment, deploy)
    redis_client = RedisWrapper(host=host, port=port, socket_timeout=timeout,
                                socket_connect_timeout=timeout)
    redis_client2 = RedisWrapper(host='localhost', port=port, socket_timeout=timeout,
                                socket_connect_timeout=timeout)
    cloudwatch = CwBotoWrapper()
    metric_name = 'queue_length'
    dimension = 'queue'
##    response = cloudwatch.list_metrics(Namespace=namespace,
##                                       MetricName=metric_name,
##                                       Dimensions=[{'Name': dimension}])
    existing_queues = []
##    for m in response["Metrics"]:
##        existing_queues.extend(
##            [d['Value'] for d in m["Dimensions"] if (
##                d['Name'] == dimension and
##                not d['Value'].endswith(".pidbox") and
##                not d['Value'].startswith("_kombu"))])

#    print("keys {}".format(redis_client.keys()))
    redis_queues = set([k.decode() for k in redis_client.keys()
                        if (redis_client.type(k) == b'list' and
                            not k.decode().endswith(".pidbox") and
                            not k.decode().startswith("_kombu"))])

    all_queues = existing_queues + list(
        set(redis_queues).difference(existing_queues)
    )
    queue_age_hash = redis_client2.hgetall(QUEUE_AGE_HASH_NAME)
    old_state = unpack_state(queue_age_hash)

    metric_data = []

    queue_first_items = {}
    current_time = datetime.datetime.now()
    for queue_name in all_queues:
        queue_first_items[queue_name] = redis_client.lindex(queue_name, 0)

    print("old state {}".format(old_state))
    print("\n\nqueue_first_items {}\n\n".format(queue_first_items))
    new_state = build_new_state(old_state, queue_first_items, current_time)
    print("new state {}".format(new_state))

    redis_client2.delete(QUEUE_AGE_HASH_NAME)
    redis_client2.hmset(QUEUE_AGE_HASH_NAME, pack_state(new_state))

    for queue_name in all_queues:
        metric_data.append({
            'MetricName': metric_name,
            'Dimensions': [{
                "Name": dimension,
                "Value": queue_name
            }],
            'Value': redis_client.llen(queue_name)
        })

    if len(metric_data) > 0:
        for metric_data_grouped in grouper(metric_data, max_metrics):
            print("metric_data {}".format(metric_data))
            #cloudwatch.put_metric_data(Namespace=namespace, MetricData=metric_data)

    for queue in all_queues:
        dimensions = [{'Name': dimension, 'Value': queue}]
        queue_threshold = threshold
        if queue in thresholds:
            queue_threshold = thresholds[queue]
        # Period is in seconds
        period = 60
        evaluation_periods = 15
        comparison_operator = "GreaterThanThreshold"
        treat_missing_data = "notBreaching"
        statistic = "Maximum"
        actions = [sns_arn]
        alarm_name = "{}-{} {} queue length over threshold".format(environment,
                                                                   deploy,
                                                                   queue)

        print('Creating or updating alarm "{}"'.format(alarm_name))
        cloudwatch.put_metric_alarm(AlarmName=alarm_name,
                                    AlarmDescription=alarm_name,
                                    Namespace=namespace,
                                    MetricName=metric_name,
                                    Dimensions=dimensions,
                                    Period=period,
                                    EvaluationPeriods=evaluation_periods,
                                    TreatMissingData=treat_missing_data,
                                    Threshold=queue_threshold,
                                    ComparisonOperator=comparison_operator,
                                    Statistic=statistic,
                                    InsufficientDataActions=actions,
                                    OKActions=actions,
                                    AlarmActions=actions)

# Stolen right from the itertools recipes
# https://docs.python.org/3/library/itertools.html#itertools-recipes
def grouper(iterable, n, fillvalue=None):
    "Collect data into fixed-length chunks or blocks"
    # grouper('ABCDEFG', 3, 'x') --> ABC DEF Gxx"
    args = [iter(iterable)] * n
    chunks = zip_longest(*args, fillvalue=fillvalue)
    # Remove Nones in function
    for chunk in chunks:
        yield [v for v in chunk if v is not None]

if __name__ == '__main__':
    check_queues()

import boto3
from botocore.exceptions import ClientError
import backoff
import csv
import click

MAX_TRIES = 5


class S3BotoWrapper:
    def __init__(self):
        self.client = boto3.resource('s3')

    @backoff.on_exception(backoff.expo, ClientError, max_tries=MAX_TRIES)
    def list_buckets(self):
        return self.client.buckets.all()

    @backoff.on_exception(backoff.expo, ClientError, max_tries=MAX_TRIES)
    def get_bucket(self, bucket_name):
        return self.client.Bucket(bucket_name)

    @backoff.on_exception(backoff.expo, ClientError, max_tries=MAX_TRIES)
    def get_object(self, bucket_name, obj_key):
        return self.client.Object(bucket_name, obj_key)


def objects_puller(environment):
    client = S3BotoWrapper()
    obj_dict = {}
    temp_dict = {}
    for bucket in client.list_buckets():
        if environment in bucket.name:
            obj_dict[bucket.name] = {}
            bucket_info = client.get_bucket(bucket.name)
            for obj in bucket_info.objects.all():
                key = client.get_object(bucket.name, obj.key)
                if key.server_side_encryption is None:
                    temp_dict[obj.key] = str(key.server_side_encryption)
            obj_dict[bucket.name] = temp_dict
    return obj_dict


def csv_writer(object_dict):
    with open('csv_file.csv', mode='w', newline='') as csv_file:

        # Create a CSV writer object
        writer = csv.writer(csv_file)

        # Loop through the data and write each row to the file
        for category, items in object_dict.items():
            for item, value in items.items():
                writer.writerow([category, item, value])


@click.command()
@click.option('--environment', required=True, help='Use to identify the environment')
def controller(environment):
    obj_dict = objects_puller(environment)
    csv_writer(obj_dict)


if __name__ == '__main__':
    controller()


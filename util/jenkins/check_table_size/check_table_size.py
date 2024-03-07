import boto3
from botocore.exceptions import ClientError
import sys
import backoff
import pymysql
import click

MAX_TRIES = 5


class EC2BotoWrapper:
    def __init__(self):
        self.client = boto3.client("ec2")

    @backoff.on_exception(backoff.expo, ClientError, max_tries=MAX_TRIES)
    def describe_regions(self):
        return self.client.describe_regions()


class RDSBotoWrapper:
    def __init__(self, **kwargs):
        self.client = boto3.client("rds", **kwargs)

    @backoff.on_exception(backoff.expo, ClientError, max_tries=MAX_TRIES)
    def describe_db_instances(self):
        return self.client.describe_db_instances()


def rds_extractor():
    """
    Return list of all RDS instances across all the regions
    Returns:
        [
            {
                'name': name,
                'Endpoint': Endpoint of RDS
                'Port': Port of RDS
            }
        ]
    """
    client_region = EC2BotoWrapper()
    rds_list = []
    try:
        regions_list = client_region.describe_regions()
    except ClientError as e:
        print(f"Unable to connect to AWS with error :{e}")
        sys.exit(1)
    for region in regions_list["Regions"]:
        client = RDSBotoWrapper(region_name=region["RegionName"])
        response = client.describe_db_instances()
        for instance in response.get('DBInstances'):
            # This condition use to skip irrelevant RDS
            if ("prod" in instance.get("Endpoint").get("Address") or "stage" in instance.get("Endpoint").get("Address")) and "test" not in instance["DBInstanceIdentifier"]:
                temp_dict = {}
                temp_dict["name"] = instance["DBInstanceIdentifier"]
                temp_dict["Endpoint"] = instance.get("Endpoint").get("Address")
                temp_dict["Port"] = instance.get("Port")
                rds_list.append(temp_dict)
    return rds_list


def check_table_growth(rds_list, username, password, threshold, rds_threshold):
    """
        Return:
             Return list all tables that cross threshold limit
              [
                  {
                    "name": "string",
                    "db": "string",
                    "table": "string",
                    "size": "string",
                  }
              ]
        """
    try:
        table_list = []
        for db in rds_list:
            print("Checking table sizes for {}".format(db["Endpoint"]))
            format_string_header = "{:<50} {:<30} {:<70}"
            print(format_string_header.format("RDS Name","Database Name", "Table Name", "Size"))
            rds_host_endpoint = db["Endpoint"]
            rds_port = db["Port"]
            connection = pymysql.connect(host=rds_host_endpoint,
                                         port=rds_port, user=username, password=password)
            # prepare a cursor object using cursor() method
            cursor = connection.cursor()
            # execute SQL query using execute() method.
            cursor.execute("""
            SELECT 
            table_schema as `Database`, 
            table_name AS `Table`, 
            round(((data_length + index_length) / 1024 / 1024), 2) `Size in MB` 
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema') 
            ORDER BY (data_length + index_length) DESC;
            """)

            rds_result = cursor.fetchall()
            cursor.close()
            connection.close()
            if db["name"] in rds_threshold:
                threshold_limit = rds_threshold[db["name"]]
            else:
                threshold_limit = threshold
            for tables in rds_result:
                temp_dict = {}
                if tables[2] is not None:
                    temp_dict["rds"] = db["name"]
                    temp_dict["db"] = tables[0]
                    temp_dict["table"] = tables[1]
                    temp_dict["size"] = tables[2]
                    format_string = "{:<50} {:<30} {:<70} {:>20,}"
                    print(format_string.format(temp_dict["rds"], temp_dict["db"], temp_dict["table"], temp_dict["size"]) + " MB")
                    if tables[2] > float(threshold_limit):
                        table_list.append(temp_dict)
        return table_list
    except Exception as ex:
        print(ex)
        sys.exit(1)


@click.command()
@click.option('--username', envvar='USERNAME', required=True)
@click.option('--password', envvar='PASSWORD', required=True)
@click.option('--threshold', required=True, help='Threshold for tables')
@click.option('--rdsthreshold', type=(str, int), multiple=True, help='Specific RDS threshold')
@click.option('--rdsignore', '-i', multiple=True, help='RDS name tags to not check, can be specified multiple times')
def controller(username, password, threshold, rdsthreshold, rdsignore):
    """
    Control execution of all other functions
    Arguments:
        username (str):
            Get this from cli args

        password (str):
            Get this from cli args
        threshold (str):
            Get this from cli args
        rdsthreshold (str, int):
            Get this from cli args
    """
    rds_threshold = dict(rdsthreshold)
    rds_list = rds_extractor()
    filtered_rds_list = list([x for x in rds_list if x['name'] not in rdsignore])
    table_list = check_table_growth(filtered_rds_list, username, password, threshold, rds_threshold)
    if len(table_list) > 0:
        print("#############################")
        print("# Tables over the threshold #")
        print("#############################")
        format_string_header = "{:<50} {:<30} {:<70}"
        print(format_string_header.format("RDS Name","Database Name", "Table Name", "Size"))
        format_string = "{:<50} {:<30} {:<70} {:>20,}"
        for items in table_list:
            print(format_string.format(items["rds"], items["db"], items["table"], items["size"]) + " MB")
        exit(1)
    exit(0)


if __name__ == '__main__':
    controller()


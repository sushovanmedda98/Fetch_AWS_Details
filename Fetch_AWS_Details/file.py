import boto3
import pandas as pd
from botocore.exceptions import ClientError

def get_all_regions(service_name):
    # Use EC2 client to list all regions - works for most services
    ec2 = boto3.client('ec2', region_name='us-east-1')
    response = ec2.describe_regions(AllRegions=True)
    regions = [region['RegionName'] for region in response['Regions'] if region['OptInStatus'] in ('opt-in-not-required', 'opted-in')]
    return regions

def fetch_ec2_instances(region):
    ec2_client = boto3.client('ec2', region_name=region)
    try:
        response = ec2_client.describe_instances()
    except ClientError as e:
        print(f"Skipping EC2 in region {region} due to error: {e}")
        return pd.DataFrame()

    data = []
    for reservation in response.get('Reservations', []):
        for instance in reservation.get('Instances', []):
            tags = {tag['Key']: tag['Value'] for tag in instance.get('Tags', [])} if instance.get('Tags') else {}
            data.append({
                'Region': region,
                'InstanceId': instance.get('InstanceId'),
                'InstanceType': instance.get('InstanceType'),
                'State': instance.get('State', {}).get('Name'),
                'LaunchTime': instance.get('LaunchTime').replace(tzinfo=None) if instance.get('LaunchTime') else None,
                'PublicIP': instance.get('PublicIpAddress'),
                'PrivateIP': instance.get('PrivateIpAddress'),
                'AvailabilityZone': instance.get('Placement', {}).get('AvailabilityZone'),
                'Name': tags.get('Name', ''),
                'Tags': tags
            })
    return pd.DataFrame(data)

def fetch_rds_instances(region):
    rds_client = boto3.client('rds', region_name=region)
    try:
        response = rds_client.describe_db_instances()
    except ClientError as e:
        print(f"Skipping RDS in region {region} due to error: {e}")
        return pd.DataFrame()

    data = []
    for db in response.get('DBInstances', []):
        data.append({
            'Region': region,
            'DBInstanceIdentifier': db.get('DBInstanceIdentifier'),
            'DBInstanceClass': db.get('DBInstanceClass'),
            'Engine': db.get('Engine'),
            'EngineVersion': db.get('EngineVersion'),
            'DBInstanceStatus': db.get('DBInstanceStatus'),
            'Endpoint': db.get('Endpoint', {}).get('Address'),
            'AvailabilityZone': db.get('AvailabilityZone'),
            'StorageType': db.get('StorageType'),
            'AllocatedStorage (GB)': db.get('AllocatedStorage'),
            'Name': next((tag['Value'] for tag in db.get('TagList', []) if tag['Key'] == 'Name'), '') if db.get('TagList') else ''
        })
    return pd.DataFrame(data)

def fetch_opensearch_domains(region):
    es_client = boto3.client('opensearch', region_name=region)  # Note: 'opensearch' is the new service name in boto3
    try:
        domain_list = es_client.list_domain_names()['DomainNames']
    except ClientError as e:
        print(f"Skipping OpenSearch in region {region} due to error: {e}")
        return pd.DataFrame()

    data = []
    for domain in domain_list:
        domain_name = domain['DomainName']
        try:
            details = es_client.describe_domain(DomainName=domain_name)['DomainStatus']
        except ClientError as e:
            print(f"Error fetching details for domain {domain_name} in {region}: {e}")
            continue

        tags = {}
        try:
            tags_response = es_client.list_tags(ARN=details['ARN'])
            tags = {tag['Key']: tag['Value'] for tag in tags_response.get('TagList', [])}
        except Exception:
            pass

        data.append({
            'Region': region,
            'DomainName': domain_name,
            'EngineVersion': details.get('EngineVersion') or details.get('ElasticsearchVersion'),
            'Endpoint': details.get('Endpoint'),
            'ARN': details.get('ARN'),
            'InstanceType': details.get('ClusterConfig', {}).get('InstanceType') or details.get('ElasticsearchClusterConfig', {}).get('InstanceType'),
            'InstanceCount': details.get('ClusterConfig', {}).get('InstanceCount') or details.get('ElasticsearchClusterConfig', {}).get('InstanceCount'),
            'DedicatedMasterEnabled': details.get('ClusterConfig', {}).get('DedicatedMasterEnabled') or details.get('ElasticsearchClusterConfig', {}).get('DedicatedMasterEnabled'),
            'ZoneAwarenessEnabled': details.get('ClusterConfig', {}).get('ZoneAwarenessEnabled') or details.get('ElasticsearchClusterConfig', {}).get('ZoneAwarenessEnabled'),
            'Created': details.get('Created'),
            'Deleted': details.get('Deleted'),
            'Name': tags.get('Name', ''),
            'Tags': tags
        })
    return pd.DataFrame(data)

def export_to_excel(ec2_df, rds_df, os_df):
    with pd.ExcelWriter("aws_resources_all_regions.xlsx", engine="openpyxl") as writer:
        ec2_df.to_excel(writer, sheet_name='EC2_Instances', index=False)
        rds_df.to_excel(writer, sheet_name='RDS_Instances', index=False)
        os_df.to_excel(writer, sheet_name='OpenSearch_Domains', index=False)
    print("✅ Export completed: aws_resources_all_regions.xlsx")

def main():
    print("Discovering all AWS regions...")
    regions = get_all_regions('ec2')
    print(f"Found {len(regions)} regions")

    all_ec2 = []
    all_rds = []
    all_os = []

    for region in regions:
        print(f"\nFetching EC2 instances in region: {region}")
        ec2_df = fetch_ec2_instances(region)
        print(f"EC2 instances fetched: {len(ec2_df)}")
        all_ec2.append(ec2_df)

        print(f"Fetching RDS instances in region: {region}")
        rds_df = fetch_rds_instances(region)
        print(f"RDS instances fetched: {len(rds_df)}")
        all_rds.append(rds_df)

        print(f"Fetching OpenSearch domains in region: {region}")
        os_df = fetch_opensearch_domains(region)
        print(f"OpenSearch domains fetched: {len(os_df)}")
        all_os.append(os_df)

    # Combine all regional data into single DataFrames
    final_ec2_df = pd.concat(all_ec2, ignore_index=True) if all_ec2 else pd.DataFrame()
    final_rds_df = pd.concat(all_rds, ignore_index=True) if all_rds else pd.DataFrame()
    final_os_df = pd.concat(all_os, ignore_index=True) if all_os else pd.DataFrame()

    export_to_excel(final_ec2_df, final_rds_df, final_os_df)

if __name__ == "__main__":
    main()
# This script fetches details of EC2 instances, RDS instances, and OpenSearch domains across all AWS regions
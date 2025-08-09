Create IAM User and add the custom Policy

{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Action": "ec2:DescribeInstances",
			"Resource": "*"
		},
		{
			"Effect": "Allow",
			"Action": "rds:DescribeDBInstances",
			"Resource": "*"
		},
		{
			"Effect": "Allow",
			"Action": [
				"es:ListDomainNames",
				"es:DescribeElasticsearchDomain"
			],
			"Resource": "*"
		},
		{
			"Effect": "Allow",
			"Action": "ec2:DescribeRegions",
			"Resource": "*"
		}
	]
}

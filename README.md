# AWS permissions
### Services (sets SCP policy)
* EC2
* Key management
### IAM policy
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAllEC2",
      "Effect": "Allow",
      "Action": "ec2:*",
      "Resource": "*"
    }
  ]
}

# Azure permissions
more stuff

# GCP permissions
more more stuff

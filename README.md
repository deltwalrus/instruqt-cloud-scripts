# AWS permissions
### Services (sets SCP policy)
* EC2
* Key management
### IAM policy
```json
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
```

# Azure permissions
User-assigned role: _Contributor_
Admin-assigned role: _Contributor_

# GCP permissions
more more stuff

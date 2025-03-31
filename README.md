# AWS requirements
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

# Azure requirements
`pip install azure-identity azure-mgmt-resource azure-mgmt-network azure-mgmt-compute`
User-assigned role: _Contributor_
Admin-assigned role: _Contributor_

# GCP requirements
more more stuff

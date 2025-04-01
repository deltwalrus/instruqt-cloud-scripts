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
User-assigned role: _Contributor_  

# GCP requirements
User role: _roles/writer_  
Required services:
- Service Usage API
- Compute Engine API
*NB:* Not all GCP machine types are available in all geographic zones, see https://cloud.google.com/compute/docs/regions-zones#available for details
*ALL* cloud accounts _must_ have at least one region explicitly specified or track setup will fail. *ALL* cloud accounts _must also_ have roles specifically enumerated or else _they will receive *no* permissions_.

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
User roles:  
- _roles/writer_
- _roles/compute.securityAdmin_ (for firewall creation)  

Required services:  
- Service Usage API
- Compute Engine API  

*NB:* Not all GCP machine types are available in all geographic zones, see https://cloud.google.com/compute/docs/regions-zones#available for details

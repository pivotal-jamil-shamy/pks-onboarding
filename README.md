# pks-onboarding
## PKS Onboarding Concourse Pipeline

This repository contains Concourse pipeline for PKS cluster onboarding.

Prerequisites:

* PKS v1.5
* On Ops Manager, PKS Tile's UAA is configured with use **LDAP Server as external authentication mechanisms**. 
* On Ops Manager, PKS Tile's UAA is configured to **enable created clusters to use UAA as the OIDC provider**.
* It assuems that LDAP Server is used to manage groups and users access.
* PKS UAA has been mapped with LDAP group for cluster admin.
  ```
  uaac group map --name pks.clusters.admin \
     CN=pks-cluster-admin,OU=Groups,DC=dsgtech,DC=co
  ```
* Service account has been created on UAA for Concourse CI.
  ```
  uaac user add srv-pksadmin --email \
       srv-pksadmin@dsgtech.com -p <password>
  uaac member add pks.clusters.admin srv-pksadmin
  ```

Concourse fly command:
```
cd pks/ci
fly -t pks-environment set-pipeline -p pks-onboarding -c pipeline.yml -l sample-params.yml
```

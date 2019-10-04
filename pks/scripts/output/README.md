Output files are located in this directory

File format:

<ADGroupName>-cluster-role-binding.yaml
Above file is used by kubernetes to create a role binding to the given AD group with admin role.

kubeconfig-<ADGroupName>
Above file is generated with cluster skeleton details and needs to be given to the end users.
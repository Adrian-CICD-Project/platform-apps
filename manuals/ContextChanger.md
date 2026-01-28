# Setting context for test
kubectl config use-context devops-poc01-test

# Retrieving AKS credentials for test 
az aks get-credentials --resource-group rg-devops-poc01 --name devops-poc01-test --overwrite-existing

# Setting context for prod
kubectl config use-context devops-poc01-prod

# Retrieving AKS credentials for prod 
az aks get-credentials --resource-group rg-devops-poc01 --name devops-poc01-prod --overwrite-existing

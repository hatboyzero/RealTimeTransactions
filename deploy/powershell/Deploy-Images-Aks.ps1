#! /usr/bin/pwsh

Param(
    [parameter(Mandatory=$false)][string]$name = "ms-payments-demo",
    [parameter(Mandatory=$false)][string]$resourceGroup,
    [parameter(Mandatory=$true)][string]$locations,
    [parameter(Mandatory=$false)][string]$acrName,
    [parameter(Mandatory=$false)][string]$acrResourceGroup=$resourceGroup,
    [parameter(Mandatory=$false)][string]$tag="latest",
    [parameter(Mandatory=$false)][string]$charts = "*",
    [parameter(Mandatory=$false)][string]$valuesFile = "",
    [parameter(Mandatory=$false)][string]$namespace = "",
    [parameter(Mandatory=$false)][string][ValidateSet('prod','staging','none','custom', IgnoreCase=$false)]$tlsEnv = "prod",
    [parameter(Mandatory=$false)][string]$tlsHost="",
    [parameter(Mandatory=$false)][string]$tlsSecretName="tls-prod",
    [parameter(Mandatory=$false)][bool]$autoscale=$false
)

function validate {
    $valid = $true

    if ([string]::IsNullOrEmpty($aksName)) {
        Write-Host "No AKS name. Use -aksName to specify name" -ForegroundColor Red
        $valid=$false
    }
    if ([string]::IsNullOrEmpty($resourceGroup))  {
        Write-Host "No resource group. Use -resourceGroup to specify resource group." -ForegroundColor Red
        $valid=$false
    }

    if ([string]::IsNullOrEmpty($aksHost) -and $tlsEnv -ne "custom")  {
        Write-Host "AKS host of HttpRouting can't be found. Are you using right AKS ($aksName) and RG ($resourceGroup)?" -ForegroundColor Red
        $valid=$false
    }     
    if ([string]::IsNullOrEmpty($acrLogin))  {
        Write-Host "ACR login server can't be found. Are you using right ACR ($acrName) and RG ($resourceGroup)?" -ForegroundColor Red
        $valid=$false
    }

    if ($tlsEnv -eq "custom" -and [string]::IsNullOrEmpty($tlsSecretName)) {
        Write-Host "If tlsEnv is custom must use -tlsSecretName to set the TLS secret name (you need to install this secret manually)"
        $valid=$false
    }

    if ($tlsEnv -eq "custom" -and [string]::IsNullOrEmpty($tlsHost)) {
        Write-Host "If tlsEnv is custom must use -tlsHost to set the hostname of AKS (inferred name of Http Application Routing won't be used)"
        $valid=$false
    }

    if ($valid -eq $false) {
        exit 1
    }
}

function createHelmCommand([string]$command) {
    $tlsSecretNameToUse = ""
    if ($tlsEnv -eq "staging") {
        $tlsSecretNameToUse = "tls-staging"
    }
    if ($tlsEnv -eq "prod") {
        $tlsSecretNameToUse = "tls-prod"
    }
    if ($tlsEnv -eq "custom") {
        $tlsSecretNameToUse=$tlsSecretName
    }	    

    $newcommand = $command

    if (-not [string]::IsNullOrEmpty($namespace)) {
        $newcommand = "$newcommand --namespace $namespace" 
    }

    if (-not [string]::IsNullOrEmpty($tlsSecretNameToUse)) {
        $newcommand = "$newcommand --set ingress.tls[0].secretName=$tlsSecretNameToUse --set ingress.tls[0].hosts='{$aksHost}'"
    }

    return "$newcommand";
}

$locArray = $locations.Split(",")

$i = 0
foreach($location in $locArray)
{
    $queryString = "[?location=='$($location.toLower())'].{name: name}"
    $aksName = $(az aks list -g $resourceGroup --query $queryString -o json | ConvertFrom-Json).name
    az aks get-credentials -n $aksName -g $resourceGroup --admin

    Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " Deploying images on cluster $aksName"  -ForegroundColor Yellow
    Write-Host " "  -ForegroundColor Yellow
    Write-Host " Additional parameters are:"  -ForegroundColor Yellow
    Write-Host " Release Name: $name"  -ForegroundColor Yellow
    Write-Host " AKS to use: $aksName in RG $resourceGroup and ACR $acrName"  -ForegroundColor Yellow
    Write-Host " Images tag: $tag"  -ForegroundColor Yellow
    Write-Host " TLS/SSL environment to enable: $tlsEnv"  -ForegroundColor Yellow
    Write-Host " Namespace (empty means the one in .kube/config): $namespace"  -ForegroundColor Yellow
    Write-Host " --------------------------------------------------------" 

    if ($acrName -ne "bydtochatgptcr") {
        $acrName = $(az acr list -g $resourceGroup --query $queryString -o json | ConvertFrom-Json).name
        $acrLogin=$(az acr show -n $acrName -g $acrResourceGroup -o json| ConvertFrom-Json).loginServer
        Write-Host "acr login server is $acrLogin" -ForegroundColor Yellow
    }
    else {
        $acrLogin="bydtochatgptcr.azurecr.io"
    }

    if ($tlsEnv -ne "custom" -and [String]::IsNullOrEmpty($tlsHost)) {
        $aksHost=$(az aks show -n $aksName -g $resourceGroup --query addonProfiles.httpapplicationrouting.config.HTTPApplicationRoutingZoneName -o json | ConvertFrom-Json)

        if (-not $aksHost) {
            $aksHost=$(az aks show -n $aksName -g $resourceGroup --query addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName -o json | ConvertFrom-Json)
        }

        Write-Host "acr login server is $acrLogin" -ForegroundColor Yellow
        Write-Host "aksHost is $aksHost" -ForegroundColor Yellow
    }
    else {
        $aksHost=$tlsHost
    }

    validate

    Push-Location $($MyInvocation.InvocationName | Split-Path)

    & ./DeployCertManager.ps1
    & ./DeployTlsSupport.ps1 -sslSupport prod -resourceGroup $resourceGroup -aksName $aksName

    Push-Location $(Join-Path .. helm)

    $aksArray = $aksNames.Split(',')
    $locArray = $locations.Split(',')

    Write-Host "Deploying charts $charts" -ForegroundColor Yellow

    if ([String]::IsNullOrEmpty($valuesFile)) {
        $valuesFile="gvalues.yaml"
    }

    Write-Host "Configuration file used is ${valuesFile}${i}.yml" -ForegroundColor Yellow

    if ($charts.Contains("api") -or  $charts.Contains("*")) {
        Write-Host "API chart - api" -ForegroundColor Yellow
        $command = "helm upgrade --install $name-api ./payments-api -f ${valuesFile}${i}.yml --set ingress.hosts='{$aksHost}' --set image.repository=$acrLogin/payments-api --set image.tag=$tag --set hpa.activated=$autoscale"
        $command = createHelmCommand $command 
        Invoke-Expression "$command"
    }

    if ($charts.Contains("web") -or  $charts.Contains("*")) {
        Write-Host "Webapp chart - web" -ForegroundColor Yellow
        $command = "helm upgrade --install $name-worker ./payments-worker -f ${valuesFile}${i}.yml --set image.repository=$acrLogin/payments-worker-service --set image.tag=$tag  --set hpa.activated=$autoscale"
        $command = createHelmCommand $command
        Invoke-Expression "$command"
    }

    Pop-Location
    Pop-Location

    Write-Host "MS Payments Demo deployed on AKS" -ForegroundColor Yellow

    $i++
}
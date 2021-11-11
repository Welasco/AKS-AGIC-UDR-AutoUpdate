[CmdletBinding()]
Param
(
    [Parameter (Mandatory= $false)]
    [object]$WebhookData,
    [Parameter (Mandatory= $true)]
    [string]$AppGWUDRRGName,
    [Parameter (Mandatory= $true)]
    [string]$AppGWUDRName
)
#The parameter name must to be called as WebHookData otherwise the webhook does not work.

$VerbosePreference = 'continue'

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave –Scope Process

$connection = Get-AutomationConnection -Name AzureRunAsConnection

# Wrap authentication in retry logic for transient network failures
$logonAttempt = 0
while(!($connectionResult) -And ($logonAttempt -le 10))
{
    $LogonAttempt++
    # Logging in to Azure...
    $connectionResult =    Connect-AzAccount `
                               -ServicePrincipal `
                               -Tenant $connection.TenantID `
                               -ApplicationId $connection.ApplicationID `
                               -CertificateThumbprint $connection.CertificateThumbprint

    Start-Sleep -Seconds 30
}
# Static variables for AppGW UDR
Write-Output "AppGWUDRRGName: $AppGWUDRRGName"
Write-Output "AppGWUDRName: $AppGWUDRName"

$appgwrt = Get-AzRouteTable -ResourceGroupName $AppGWUDRRGName -Name $AppGWUDRName

# If runbook was called from Webhook, WebhookData will not be null.
if ($WebHookData){

    $WebHook = $WebHookData.RequestBody | ConvertFrom-Json
    $resourceGroupName = $WebHook.data.context.activityLog.resourceGroupName
    $resourceID = $WebHook.data.context.activityLog.resourceId
    $resourceType = $WebHook.data.context.activityLog.resourceType
    $resourceProviderName = $WebHook.data.context.activityLog.resourceProviderName
    $subscriptionId = $WebHook.data.context.activityLog.subscriptionId
    $resourceName = $resourceID.Split("/")[-1]

    Write-OutPut "ResourceGroupName: " $resourceGroupName
    Write-OutPut "Resource ID: "$resourceID
    Write-OutPut "Resource Type: "$resourceType
    Write-OutPut "Resource Provider Name: "$resourceProviderName
    Write-OutPut "Resource Subscription ID: " $subscriptionId
    Write-OutPut "Resource Name: "$resourceName

    $aksrt = Get-AzRouteTable -ResourceGroupName $resourceGroupName -Name $resourceName
    $routesChanged = $false
    # Looping AKS UDR and adding POD CIDR Node to AppGW UDR
    foreach ($aksroute in $aksrt.Routes) {
        if ($aksroute.Name -like "aks*" -and $aksroute.Name -like "*vmss*") {
            $aksRouteName = $aksroute.Name
            $aksRouteAddressPrefix = $aksroute.AddressPrefix
            $aksRouteNextHopType = $aksroute.NextHopType
            $aksRouteNextHopIpAddress = $aksroute.NextHopIpAddress
            
            $checkExist = $false
            foreach ($appgwroute in $appgwrt.Routes) {
                if ($aksRouteName -eq $appgwroute.Name) {
                    $checkExist = $true
                    break
                }
            }
            if ($checkExist -eq $false) {
                Write-Output "Route $aksRouteName not found in $appgwudrname. Adding route to $appgwudrname"
                $routesChanged = $true
                Add-AzRouteConfig -RouteTable $appgwrt -Name $aksRouteName -AddressPrefix $aksRouteAddressPrefix -NextHopType $aksRouteNextHopType -NextHopIpAddress $aksRouteNextHopIpAddress | Out-Null
            }
        }
    }
    # Looping AppGW UDR and removing POD Node CIDR from AppGW UDR based in AKS UDR
    foreach ($appgwroute in $appgwrt.Routes) {
        if ($appgwroute.Name -like "aks*" -and $appgwroute.Name -like "*vmss*") {
            $appgwRouteName = $appgwroute.Name
            $appgwRouteAddressPrefix = $appgwroute.AddressPrefix
            $appgwRouteNextHopType = $appgwroute.NextHopType
            $appgwRouteNextHopIpAddress = $appgwroute.NextHopIpAddress
            
            $checkExist = $false
            foreach ($aksroute in $aksrt.Routes) {
                if ($appgwRouteName -eq $aksroute.Name) {
                    $checkExist = $true
                    break
                }
            }
            if ($checkExist -eq $false) {
                Write-Output "Route $appgwRouteName not found in $resourceName. Deleting route from $appgwudrname"
                $routesChanged = $true
                Remove-AzRouteConfig -RouteTable $appgwrt -Name $appgwRouteName | Out-Null
            }
        }
    }
    # Saving Change
    if ($routesChanged) {
        Write-Output "Route changed detected. Saving change"
        Write-Output ($appgwrt | ConvertTo-Json -Depth 100)
        Set-AzRouteTable -RouteTable $appgwrt -Confirm:$false
    }

}
else
{
    Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
}
Write-Output "Script finished"
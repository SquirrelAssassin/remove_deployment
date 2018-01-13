function Remove-Deployment {
# Tested on Powershell Version 5
# Tested with azurerm modules 5.5.1 (install-module azurerm)
# Requires azure sign in assistant to be installed
    Param
    (
        [parameter(Mandatory = $true)]
        [String]$deploymentname,
        [parameter(Mandatory = $true)]
        [String]$resourcegroup,
        [parameter(Mandatory = $true)]
        [String]$subscriptionId =,
        [parameter(Mandatory = $true)]
        [String]$applicationid,
        [parameter(Mandatory = $true)]
        [String]$applicationkey,
        [parameter(Mandatory = $true)]
        [String]$tenantid
    )

    # Login
    $pass = ConvertTo-SecureString $applicationKey -AsPlainText –Force 
    $cred = New-Object -TypeName pscredential –ArgumentList $applicationId, $pass
    Login-AzureRmAccount -Credential $cred -TenantId $tenantId -ServicePrincipal
    Select-AzureRmSubscription -SubscriptionId $subscriptionId


    # Gather Info on the deployment
    $operation = (Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $DeploymentName -ResourceGroupName $resourcegroup).Properties
    $removalinorder = $operation | Sort-Object -Property timestamp -Descending

    # Gather all VM's
    $vmarray = @()
    foreach ($item in $removalinorder) {
        if ($item.targetResource.resourceType -eq "Microsoft.Compute/virtualMachines") {
            $vmarray += $item.targetResource.id
        }
    }

    # Use a workflow to remove vms in parallel
    workflow removevm {
        param(
            # Parameter help description
            [Parameter(Mandatory = $true)]
            [array]$vms,
            [parameter(Mandatory = $true)]
            [String]$subscriptionId,
            [parameter(Mandatory = $true)]
            [String]$applicationid,
            [parameter(Mandatory = $true)]
            [String]$applicationkey,
            [parameter(Mandatory = $true)]
            [String]$tenantid
        )

        foreach -parallel ($vm in $vms) {
            #Login
            $pass = ConvertTo-SecureString $applicationKey -AsPlainText –Force 
            $cred = New-Object -TypeName pscredential –ArgumentList $applicationId, $pass
            Login-AzureRmAccount -Credential $cred -TenantId $tenantId -ServicePrincipal
            Select-AzureRmSubscription -SubscriptionId $subscriptionId

            #Remove VM's
            write-output "Removeing $($vm)"
            Remove-AzureRmResource -ResourceId $vm -force -ErrorAction Continue

        }   
    }

    # Run Workflow
    removevm -vms $vmarray -subscriptionId $subscriptionId -tenantid $tenantid -applicationid $applicationid -applicationkey $applicationkey
    
    # Remove all other resources
    foreach ($resource in $removalinorder) {
        if (($resource.targetResource.resourceType -ne "Microsoft.Compute/virtualMachines") -and ($resource.provisioningOperation -ne "EvaluateDeploymentOutput") -and ($resource.resourceType -ne "Microsoft.Network/loadBalancers/inboundNatRules")) {
                Remove-AzureRmResource -ResourceId $resource.targetResource.id -force -ErrorAction Continue 
                write-host "removed resource $($resource.targetResource.id)"
            }
        }

    # Remove all managed disks
    $searchnumber = ((((($removalinorder[1].targetResource.id).split('/')) | Select-Object -SkipLast 2) | Select-Object -Last 1).split('-') | Select-Object -SkipLast 1) | Select-Object -Last 1
    $disks = Get-AzureRmResource | Where-Object resourcetype -eq "Microsoft.Compute/disks" | Where-Object resourcename -like "*$($searchnumber)*" | Where-Object resourcegroupname -eq $resourcegroup

    foreach ($disk in $disks) {
        write-host "removing disk $($disk.Name)"
        Remove-AzureRmResource -ResourceId $disk.ResourceId -force -erroraction Continue
    }
}

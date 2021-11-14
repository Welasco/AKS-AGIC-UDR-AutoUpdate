Using AKS kubenet egrees control with AGIC
==========================================

Table of Contents
=================

0. [Executive Summary](#0-executive-summary)

1. [Network Plugins](#1-network-plugins)

2. [IP address availability and exhaustion](#2-ip-address-availability-and-exhaustion)

3. [AGIC (Application Gateway Ingress Controller)](#3-AGIC-application-gateway-ingress-controller)

4. [Network topology](#4-network-topology)

5. [Synchronizing AKS egress control UDR with Application Gateway UDR](#4-synchronizing-aks-egress-control-udr-with-application-gateway-udr)

6. [Considerations](#6-considerations)

7. [Automation Account](#7-automation-account)

8. [Azure Monitor - Alert Rule](#8-azure-monitor---alert-rule)

9. [Confirmation and test](#9-confirmation-and-test)

10. [Conclusion](#10-conclusion)

## 0. Executive Summary

When using kubenet as network plugin of an AKS cluster (for example, because IP addresses are a scarce resource in an organization) along with the Application Gateway Ingress Controller, in certain situations it is required to automatically synchronize the state of two route tables. This can be achieved using Azure Automation runbooks, which will find out the routing changes configured by AKS in the Microsoft-managed route table applied to the AKS cluster subnet, and replicate them  to a second, user-managed route table applied to the Application Gateway subnet.

## 1. Network Plugins

Kubernetes code does not include networking functionality, but instead relies in so called [network plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/) to provide connectivity between nodes and pods. AKS offers two network plugins: [kubenet](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#kubenet) and [Azure CNI](https://docs.microsoft.com/azure/aks/configure-azure-cni), which is a type of [Kubernetes CNI plugin](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#cni).

- **kubenet**: By default, AKS clusters use kubenet, and an Azure virtual network and subnet are created for you. With kubenet, nodes get an IP address from the Azure virtual network subnet. Pods receive an IP address from a logically different address space to the Azure virtual network subnet of the nodes. Since the rest of the network is unaware of the pod IP address space, Network address translation (NAT) is required so that the pods can reach resources on the Azure virtual network. The source IP address of the traffic is NAT'd to the node's primary IP address. This approach greatly reduces the number of IP addresses that you need to reserve in your network space for pods to use.

    However, for intra-cluster communication NAT is not a solution, since it would prevent bidirectional communication between pods. Instead, [User-Defined Routes (UDR)](https://docs.microsoft.com/azure/virtual-network/virtual-networks-udr-overview#user-defined) in an Azure Route Table are used that tell each node where to forward packets with destination IPs in the pod address space. By default, the route table that contains these UDRs is created and maintained by the AKS service, but you have to the option to bring your own route table for custom route management (for example, if you need to specify a default route of your own). The following diagram shows how the AKS nodes receive an IP address in the virtual network subnet, but not the pods:

    ![kubenet-overview](media/kubenet-overview.png)

- **Azure CNI**: With [Azure Container Networking Interface (CNI)](https://github.com/Azure/azure-container-networking/blob/master/docs/cni.md), every pod gets an IP address from the subnet and can be accessed directly. These IP addresses are unique across the network space, and must be planned in advance. Each node has a configuration parameter for the maximum number of pods that it supports. The equivalent number of IP addresses per node are then reserved up front for that node. This approach requires more planning, and can lead to IP address exhaustion or the need to rebuild clusters in a larger subnet as your application demands grow. You can configure the maximum pods deployable to a node at cluster create time or when creating new node pools. If you don't specify maxPods when creating new node pools, you receive a default value of 30 for Azure CNI.

## 2. IP address availability and exhaustion

With Azure CNI, a common challenge is that the network team may not be able to provide a large enough IP address range for the subnet to support the cluster requirements. If IP addresses are exhausted in the AKS subnet, undesired effects include the inability to scale or upgrade a cluster. Hence many organization with limited IP address availability turn to kubenet as their plugin of choice. Note that Microsoft is working in a new version of the Azure CNI plugin that will separate the pod and the node IP address spaces, hence reducing the impact of IP address exhaustion: see [Dynamic allocation of IPs and enhanced subnet support (preview)](https://docs.microsoft.com/azure/aks/configure-azure-cni#dynamic-allocation-of-ips-and-enhanced-subnet-support-preview) for more information.

The following basic calculations compare the difference in network IP address consumption:

- kubenet: `<max_nodes> = (2^<mask_length> - 5) - 1`
    For example, a subnet with a /24 IP address range can support up to 250 nodes in the cluster, leaving 1 free space for AKS update operations (each Azure virtual network subnet reserves 5 IP addresses: the all-zeros and all-ones as per the IP standard, and the first three non-zero IP addresses for management operations). This node count could support up to 27,500 pods (with a default maximum of 110 pods per node with kubenet). In this calculation I am ignoring potential IP addresses that would be taken up by Kubernetes LoadBalancer-type services, since those can be deployed to a separate subnet.
- Azure CNI: `<max_nodes> = (2^<mask_length> - 5) \ (<pods_per_node> + 1) - 1`
    that same basic /24 subnet range could only support a maximum of 7 nodes in the cluster with Azure CNI, since the pods take part of the IP address space. For example, with the default of 30 pods per node, each node would take up 31 IPs (the `<pods_per_node> + 1` in the equation above), so you would only have space for 8 nodes. Since you need to leave space for at least another node for AKS upgrade operations, you get the 7 nodes. With 30 pods per node, you end up in 210 pods out the same IP address space.

Hence, if IP address space is a scarce resource in an organization, kubenet is a much more efficient plugin in terms of pods per consumed IP address.

## 3. AGIC (Application Gateway Ingress Controller)

The Application Gateway Ingress Controller (AGIC) is a Kubernetes application which makes it possible for [Azure Kubernetes Service (AKS)](https://azure.microsoft.com/services/kubernetes-service/) customers to leverage [Azure Application Gateway](https://azure.microsoft.com/services/application-gateway/) L7 load-balancer to expose pods to the network outside of the Kubernetes cluster, either to the public Internet or to the rest of the internal network. As any other ingress controller, AGIC monitors the Kubernetes cluster it is hosted on and continuously updates an Application Gateway, so that selected services are exposed.

The Ingress Controller runs in its own pod on the customer’s AKS. AGIC monitors a subset of Kubernetes Resources for changes. The state of the AKS cluster is translated to Application Gateway specific configuration and applied to the [Azure Resource Manager (ARM)](https://docs.microsoft.com/azure/azure-resource-manager/management/overview).

AGIC helps eliminate the need to have another load balancer/public IP in front of the AKS cluster and avoids multiple hops in your datapath before requests reach the AKS cluster. As most other ingress controllers, Application Gateway talks to pods using their private IP directly and does not require NodePort or KubeProxy services. This also brings better performance to your deployments.

Application Gateway Ingress Controller is supported exclusively by Standard_v2 and WAF_v2 SKUs, which also brings you autoscaling benefits. Azure Application Gateway can react in response to an increase or decrease in traffic load and scale accordingly, without consuming any resources from your AKS cluster.

![agic-architecture](media/agic-architecture.png)

Regardless of which ingress controller is being used, AKS can be deployed in a secure environment with [egress control](https://docs.microsoft.com/en-us/azure/aks/egress-outboundtype). It's done using a UDR with a route 0.0.0.0/0 pointing to a Network Virtual Appliance or any other router/firewall like [Azure Firewall](https://docs.microsoft.com/azure/aks/limit-egress-traffic#restrict-egress-traffic-using-azure-firewall). However, that very same 0.0.0.0/0 route that is required to send traffic from the cluster to the Internet through a firewall is not supported by the Application Gateway v2 SKUs.

[***Unsupported scenario***](https://docs.microsoft.com/azure/application-gateway/configuration-infrastructure#supported-user-defined-routes): ***Currently Application Gateway does not support any scenario where 0.0.0.0/0 needs to be redirected through any virtual appliance, a hub/spoke virtual network, or on-premises (forced tunneling).***

***Since Application Gateway doesn't support UDR with a route 0.0.0.0/0 and it's a requirement for AKS egress control [you cannot use the same route table for both subnets](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/docs/how-tos/networking.md#with-kubenet) (Application Gateway subnet and AKS subnet).***

## 4. Network topology

Application Gateway and AKS (using egress control) both required to be deployed in dedicated subnets. In environments without egress filtering you can configure the same Microsoft-managed kubenet route table in both subnets, but if using AKS egress filtering as described above it's not possible to share the same UDR for both of them.

![AKS-private-cluster-scenario](media/AKS-private-cluster-scenario.jpg)

In this case it's required to create a dedicated UDR for Application Gateway subnet but it brings a challenge to keep the AKS (kubenet) auto managed UDR to be in sync with Application Gateway UDR, so that the Application Gateway can route traffic with destination IPs in the pod address space.

## 5. Synchronizing AKS egress control UDR with Application Gateway UDR

Every time a new node is added to the AKS cluster a new route will be automatically created in the AKS route table, with the pod address space of the new node. This route is required for Application Gateway to be able to access the backend pod. The same process happen when an AKS node is removed from the cluster.

Using Azure Monitor Alerts is possible to create an Alert Rule to trigger an Automation Account runbook every single time there is a change in the AKS-managed route table. The Automation Account can receive this event (webhook) and invoke a PowerShell script to sync the desired changes between both route tables (Application Gateway route table and AKS route table).

By following his approach you can have your customer-managed route table applied to the Application Gateway subnet always reflecting the latest state of the cluster.

## 6. Considerations

This article assume you are using AKS with VirtualMachine Scale Sets (VMSS) and not with individual Virtual Machine (VMs), which is anyway the default since a long time. The PowerShell runbook are filtering the routes based on the name of the VMSS instance name considering it will start with "aks*" and it contains "*vmss*" in the name of each route. Any other route not matching the filter will not be evaluated.

## 7. Automation Account

Create an Automation Account following the steps bellow:

1. In the [portal](https://portal.azure.com), Click the **Create a resource** button found in the upper left corner of Azure portal.

2. Select **IT & Management Tools**, and then select **Automation**. You can also search for "Automation Accounts" and create it from there.

    ![1](media/1.png)

3. Enter the Resource Group, Automation account name and Region and click next.

    ![2](media/2.png)

4. In Advanced tab don't change anything and click next.

    ![3](media/3.png)

5. Go to Review + Create and click Create.

    ![4](media/4.png)

6. Open the created Automation Account and click in Run as accounts in the left blade.

    ![5](media/5.png)

7. Under Add Azure Run As Account click Create.

    ![6](media/6.png)

8. At the end you will see the Run As Account expiration date.

    ![7](media/7.png)

9. Click in Runbooks in the left blade and click Create a runbook.

    ![8](media/8.png)

10. In Create a runbook add a runbook name, select Runbook type "PowerShell" and Runtime version 5.1. Click Create.

    ![9](media/9.png)

11. Under Edit PowerShell Runbook paste the PowerShell code which will keep both UDRs (AKS kubenet UDR and Application Gateway UDR) in sync. You can copy it from here: [UDRAutoUpdate](UDRAutoUpdate.ps1). After paste the code click in Save and Publish.

    ![10](media/10.png)

## 8. Azure Monitor - Alert Rule

Create a Azure Monitor Aler Rule to invoke the Runbook for any change/event in AKS UDR.

1. In Azure Portal look for Monitor.

    ![11](media/11.png)

2. Click in Alerts and in Alert rules.

    ![12](media/12.png)

3. In Alert rules, Click Create.

    ![13](media/13.png)

4. In Create alert rule, click Select scope.

    ![14](media/14.png)

5. In Select a resource, select your subscription under "Filber by subscription" and select Route Table under "Filter by resource type".

    ![16](media/16.png)

6. Select the UDR used by AKS and click Done.

    ![18](media/18.png)

7. Back to Create Alert rule, click Next.

    ![19](media/19.png)

8. Under Condition tab, click Add condition. In Select a signal select "All Administrative operations" and click Done.

    ![20](media/20.png)

9. Back in Condition tab, under Event Level select "Informational" and click Next.

    ![21](media/21.png)

10. Under Actions tab click Create Action Group. Select a Resource Group, and give a Action group name and a Display Name. Click Next.

    ![23](media/23.png)

11. Under Notifications tab click Next.

    ![24](media/24.png)

12. Under Actions tab, select Action Type "Automation Runbook", it will bring you to a Configure Runbook screen.

    ![25](media/25.png)

13. Under Configure Runbook, Runbook source as User, select the subscription you created the Runbook, under Automation account select the Automation account created previously and under Runbook select the runbook created previously. Now click in Parameters.

    ![27](media/27.png)

14. Under Parameters, add the Application Gateway UDR Resource Group Name and add the Application Gateway UDR to be kept in sync. Click in OK.

    ![28](media/28.png)

15. Back to configure Runbook, click OK.

    ![29](media/29.png)

16. Back to Create action group, click Review Create.

    ![30](media/30.png)

17. Review the information and click Create.

    ![31](media/31.png)

18. Back to Create alert rule click Next.

    ![32](media/32.png)

19. Under Details tab, select the Resource Group where the Alert Rule will be created and add a Alert rule name. Click in Review Create.

    ![33](media/33.png)

20. Review all the information and click Create.

    ![34](media/34.png)

21. Back to Alert rules. It will take a few seconds until the new Alert shows up. You can click refresh until it get's populated.

    ![35](media/35.png)

22. asdf asdf

    ![36](media/36.png)

## 9. Confirmation and test

You now have a Runbook with an Alert Rule. The Runbook will be executed everything single time a change happen in AKS UDR. In the steps bellow you will confirm that everthing is worked as expected by scaling in/out your AKS cluster.

1. In Azure Portal look for the Application Gateway UDR that will be in sync with AKS UDR. It's expected to be empty andd associated with the Application Gateway Subnet.

    ![37](media/37.png)

2. In Azure Portal confirm that AKS UDR has a default routing 0.0.0.0/0 pointing to a NVA (or Azure Firewall). If the AKS cluster was already created it's expected to have at least one routing entry pointing to the PODs address space of the respective node.

    ![38](media/38.png)

3. In Azure Portal go to the AKS cluster, click in Node pools. Select defaultpool and click "Scale node pool".

    ![39](media/39.png)

4. Under Scale node pool, increase/decrease the amount of nodes and click Apply.

    ![40](media/40.png)

5. Wait until the process has finished.

    ![41](media/41.png)

6. Go back to the AKS UDR and confirm that a new route entry was created/deleted based in the scale operation (in/out) you did.

    ![42](media/42.png)

7. In Azure Portal go to the Automation Account, and Runbooks. Select the runbook created previously and look at Recent Jobs. In a few seconds a new job will shows up since the AKS UDR was changed. Click in the Running job.

    ![43](media/43.png)

8. Under Input tab, is expected to see the Application Gateway UDR Resource Group localtion and the Application Gateway UDR Name. In Webhookdata it's expected to see the JSON webhook content where the PowerShell runbook script will use to parser the event.

    ![44](media/44.png)

9. Under Output tab you can see the log of the PowerShell runbook script.

    ![45](media/45.png)

10. Now bo back to Application Gateway UDR. You will see the route entries that was created based in the AKS scaling event.

    ![46](media/46.png)

## 10. Conclusion

Until Azure Application Gateway V2 (which is a requirement for AGIC) supports a UDR with routing 0.0.0.0/0, it's very hard to use AKS with kubenet network plugin since it depends on the Azure Route Tables (UDR) to route traffic to respective PODs in a Node. Using the approach above you can achieve an auto managed environment by keeping the Application Gateway UDR always in sync with AKS UDR Node routes.
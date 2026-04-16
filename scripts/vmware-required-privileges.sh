# Curated vCenter privileges required for an OpenShift Agent-based install on vSphere.
# Sourced (not executed): this file only declares VSPHERE_PRIVS_<SCOPE> arrays.
#
# Upstream source of truth:
#   https://github.com/openshift/installer/blob/main/docs/user/vsphere/privileges.md
#
# Red Hat user-facing docs (derivative):
#   https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html-single/installing_on_vmware_vsphere/index
#
# Scope-to-operation mapping (which aba operations require which scope):
#   ROOT          - session validation, tagging, storage-profile queries
#   DATACENTER    - folder create/delete when installer provisions the folder,
#                   plus full VM lifecycle (vmw-create, vmw-delete, vmw-start,
#                   vmw-stop, vmw-kill, vmw-refresh)
#   CLUSTER       - storage config + VM-to-pool assignment (when no resource
#                   pool is specified in vmware.conf)
#   DATASTORE     - VMDK space allocation + ISO upload (vmw-upload.sh)
#   NETWORK       - network-adapter wiring (vmw-create.sh: govc vm.network.add)
#   FOLDER        - VM lifecycle when aba targets a pre-created folder
#   RESOURCE_POOL - VM-to-pool assignment + disk add when a resource pool is set
#
# Adding / removing privileges: update the upstream list first, then copy here.
# Each element is the exact vSphere privilege string (e.g. Datastore.AllocateSpace).

VSPHERE_PRIVS_ROOT=(
	Cns.Searchable
	InventoryService.Tagging.AttachTag
	InventoryService.Tagging.CreateCategory
	InventoryService.Tagging.CreateTag
	InventoryService.Tagging.DeleteCategory
	InventoryService.Tagging.DeleteTag
	InventoryService.Tagging.EditCategory
	InventoryService.Tagging.EditTag
	Sessions.ValidateSession
	StorageProfile.Update
	StorageProfile.View
)

VSPHERE_PRIVS_RESOURCE_POOL=(
	Host.Config.Storage
	Resource.AssignVMToPool
	VApp.AssignResourcePool
	VApp.Import
	VirtualMachine.Config.AddNewDisk
)

VSPHERE_PRIVS_DATASTORE=(
	Datastore.AllocateSpace
	Datastore.Browse
	Datastore.FileManagement
)

VSPHERE_PRIVS_NETWORK=(
	Network.Assign
)

VSPHERE_PRIVS_FOLDER=(
	Resource.AssignVMToPool
	VApp.Import
	VirtualMachine.Config.AddExistingDisk
	VirtualMachine.Config.AddNewDisk
	VirtualMachine.Config.AddRemoveDevice
	VirtualMachine.Config.AdvancedConfig
	VirtualMachine.Config.Annotation
	VirtualMachine.Config.CPUCount
	VirtualMachine.Config.DiskExtend
	VirtualMachine.Config.DiskLease
	VirtualMachine.Config.EditDevice
	VirtualMachine.Config.Memory
	VirtualMachine.Config.RemoveDisk
	VirtualMachine.Config.Rename
	VirtualMachine.Config.ResetGuestInfo
	VirtualMachine.Config.Resource
	VirtualMachine.Config.Settings
	VirtualMachine.Config.UpgradeVirtualHardware
	VirtualMachine.Interact.GuestControl
	VirtualMachine.Interact.PowerOff
	VirtualMachine.Interact.PowerOn
	VirtualMachine.Interact.Reset
	VirtualMachine.Inventory.Create
	VirtualMachine.Inventory.CreateFromExisting
	VirtualMachine.Inventory.Delete
	VirtualMachine.Provisioning.Clone
	VirtualMachine.Provisioning.DeployTemplate
	VirtualMachine.Provisioning.MarkAsTemplate
)

VSPHERE_PRIVS_DATACENTER=(
	Resource.AssignVMToPool
	VApp.Import
	VirtualMachine.Config.AddExistingDisk
	VirtualMachine.Config.AddNewDisk
	VirtualMachine.Config.AddRemoveDevice
	VirtualMachine.Config.AdvancedConfig
	VirtualMachine.Config.Annotation
	VirtualMachine.Config.CPUCount
	VirtualMachine.Config.DiskExtend
	VirtualMachine.Config.DiskLease
	VirtualMachine.Config.EditDevice
	VirtualMachine.Config.Memory
	VirtualMachine.Config.RemoveDisk
	VirtualMachine.Config.Rename
	VirtualMachine.Config.ResetGuestInfo
	VirtualMachine.Config.Resource
	VirtualMachine.Config.Settings
	VirtualMachine.Config.UpgradeVirtualHardware
	VirtualMachine.Interact.GuestControl
	VirtualMachine.Interact.PowerOff
	VirtualMachine.Interact.PowerOn
	VirtualMachine.Interact.Reset
	VirtualMachine.Inventory.Create
	VirtualMachine.Inventory.CreateFromExisting
	VirtualMachine.Inventory.Delete
	VirtualMachine.Provisioning.Clone
	VirtualMachine.Provisioning.DeployTemplate
	VirtualMachine.Provisioning.MarkAsTemplate
	Folder.Create
	Folder.Delete
)

VSPHERE_PRIVS_CLUSTER=(
	Host.Config.Storage
	Resource.AssignVMToPool
	VApp.AssignResourcePool
	VApp.Import
	VirtualMachine.Config.AddNewDisk
)

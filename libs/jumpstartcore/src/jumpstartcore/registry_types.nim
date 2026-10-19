## Data types for the versioned operation registry.
from ./names import ReservedSubsystemNames
type
  OperationRouting* = enum orCore, orGlobal, orUnit, orUnitOrGlobal
  OperationClass* = enum ocReadOnly, ocStreaming, ocMutating
  OperationLock* = enum olNone, olUnit, olCore, olLog
  Idempotency* = enum idemNotApplicable, idemNo, idemYes
  ValueKind* = enum vkString, vkBool, vkInt, vkStringList, vkIntList, vkObjectList
  ItemShape* = enum
    ## The objects of a `vkObjectList` field.
    isNone        ## not a list of objects
    isRegistry    ## §12 defines the closed key set (`itemFields`)
    isCoreDefined ## §12 says only "(list)": objects whose keys the core defines
  FieldSpec* = object
    name*: string
    kind*: ValueKind
    optional*: bool
    defaultValue*: string
    minimum*, maximum*: int
    itemShape*: ItemShape
    itemFields*: seq[FieldSpec] ## isRegistry: every key, all required
  OperationSpec* = object
    name*: string
    idempotency*: Idempotency
    routing*: OperationRouting
    operationClass*: OperationClass
    lock*: OperationLock
    arguments*: seq[FieldSpec]
    results*: seq[FieldSpec]
  UnitState* = enum
    usActive, usInactive, usActivating, usDeactivating, usReloading, usFailed, usUnknown
  EnablementState* = enum esEnabled, esDisabled, esStatic, esIndirect, esMasked, esGenerated
const
  UnitAddressedSubsystems* = ["service", "mount", "timer", "socket", "target", "swap", "path"]
  ## Alias of names.ReservedSubsystemNames, the single source of §12.13.
  ReservedSubsystems* = ReservedSubsystemNames

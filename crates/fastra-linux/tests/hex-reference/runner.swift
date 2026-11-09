func byteChanges(_ session: HexEditSession) -> [[String:Any]] {
    session.preview.map {["offset":Int($0.offset),"old":Int($0.oldValue),"new":Int($0.newValue)]}
}
func snapshot(_ session:HexEditSession,_ source:Data)->[String:Any] {
    let applying=HexEditing.applying(Dictionary(uniqueKeysWithValues:session.preview.map{($0.offset,$0.newValue)}),to:source)!
    precondition(applying == session.applied(to:source,baseOffset:0))
    var rows:[String]=[]
    for row in 0..<((source.count+15)/16) {rows.append(session.textForRow(data:source,baseOffset:0,row:row))}
    let offset=min(8,source.count),end=min(offset+24,source.count)
    return ["revision":session.changeRevision,"dirty":session.hasChanges,"canUndo":session.canUndo,"canRedo":session.canRedo,"changes":byteChanges(session),"output":applying.map(Int.init),"rows":rows,"pageOffset":offset,"page":session.applied(to:source.subdata(in:offset..<end),baseOffset:UInt64(offset)).map(Int.init)]
}
var parseCases:[[String:Any]]=[]
func parse(_ name:String,_ text:String,_ expected:Int){
    parseCases.append(["name":name,"text":text,"expected":expected,"values":HexEditing.parseRow(text,expectedBytes:expected).map{$0.map(Int.init)} as Any? ?? NSNull()])
}
for text in ["00","0f","ff","FF","+0","+1","+9","+a","+F","-0","-1","-F","--","++","0+","0x","0X","0","000","FF00","ＦＦ","＋1","−0","٠٠","𝟘0","F\u{301}","\0F","F\0"] {parse("token",text,1)}
for expected in [0,1,2,16,17] {parse("empty","",expected);parse("spaces"," \t\r\n",expected)}
for n:UInt32 in [9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,6158,8203,65279,28,0] {
 let separator=String(UnicodeScalar(n)!);parse("scalar separator","00"+separator+"FF",2)
 parse("separator combining","00"+separator+"\u{301}"+"FF",2)
}
for separator in [" \u{301}"," \u{FE0F}"," \u{200D}"," \u{903}"," \u{1F3FB}"," \u{E0020}\u{E007F}"," \u{301}\u{FE0F}\u{200D}","\u{600} "," \u{600}"," \u{200D}😀"," \u{94D}क"," \u{300} \u{200D}\u{903}","\r\n","\r\n\u{301}"] {
 parse("cluster separator","00"+separator+"FF",2)
}
parse("extra","00 FF",1);parse("missing","00",2);parse("last partial","+F",1)
parse("seventeen",Array(repeating:"FF",count:17).joined(separator:" "),17)
parse("row",Array(repeating:"+1",count:16).joined(separator:"\u{A0}"),16)

func scenario(_ name:String,_ bytes:[UInt8],_ actions:[[String:Any]])->[String:Any] {
 let source=Data(bytes);var session=HexEditSession();var results:[[String:Any]]=[]
 for action in actions {
  let revision=session.changeRevision
  switch action["kind"] as! String {
  case "edit":session.editRow(action["text"] as! String,data:source,baseOffset:0,row:(action["offset"] as! Int)/16)
  case "undo":session.undo()
  case "redo":session.redo()
  default:preconditionFailure("unknown action")
  }
  results.append(["action":action,"changed":session.changeRevision != revision,"invalid":session.invalidRowMessage != nil,"state":snapshot(session,source)])
 }
 return ["name":name,"source":bytes.map(Int.init),"initial":snapshot(HexEditSession(),source),"steps":results]
}
func edit(_ offset:Int,_ values:[UInt8])->[String:Any]{["kind":"edit","offset":offset,"text":values.map{String(format:"%02X",$0)}.joined(separator:" ")]}
let undo:[String:Any]=["kind":"undo"],redo:[String:Any]=["kind":"redo"]
var source=(0..<48).map(UInt8.init),first=Array(source[0..<16]),again=Array(source[0..<16]),second=Array(source[16..<32]),restored=Array(source[0..<16])
first[0]=255;first[15]=0;again[0]=254;again[1]=255;again[15]=0;second[0]=170;second[15]=187
var scenarios:[[String:Any]]=[]
scenarios.append(scenario("overlap undo redo fork",source,[edit(0,first),edit(0,again),edit(16,second),undo,undo,redo,edit(0,restored),redo,undo,redo]))
scenarios.append(scenario("invalid and noops preserve redo",[UInt8](repeating:0,count:16),[edit(0,[UInt8](repeating:1,count:16)),undo,["kind":"edit","offset":0,"text":"00"],["kind":"edit","offset":0,"text":Array(repeating:"00",count:16).joined(separator:" ")],redo,["kind":"edit","offset":0,"text":Array(repeating:"+1",count:16).joined(separator:" ")],undo,undo,redo,redo]))
scenarios.append(scenario("last partial and signs",(0..<17).map(UInt8.init),[["kind":"edit","offset":16,"text":"+F"],["kind":"edit","offset":16,"text":"-0"],["kind":"edit","offset":16,"text":"-1"],undo,redo,["kind":"edit","offset":16,"text":"10"],undo,redo,["kind":"edit","offset":32,"text":"00"]]))
scenarios.append(scenario("empty",[],[undo,redo,["kind":"edit","offset":0,"text":""]]))
scenarios.append(scenario("opaque bytes and unicode whitespace",[0,255,254,239,187,191,128,129,9,10,13,0,65,66,67,255],[["kind":"edit","offset":0,"text":"00 FF FE EF BB BF 80 81 09 0A 0D 00 41 42 43 FF"],["kind":"edit","offset":0,"text":"+1 \u{301}FF FE EF BB BF 80 81 09 0A 0D -0 41 42 43 FF"],undo,redo]))

var saving=HexEditSession();let data=Data([UInt8](repeating:0,count:16));saving.editRow(Array(repeating:"01",count:16).joined(separator:" "),data:data,baseOffset:0,row:0)
let beforeSave=saving;let operation=saving.beginSave()!;let duringSave=saving
saving.editRow(Array(repeating:"02",count:16).joined(separator:" "),data:data,baseOffset:0,row:0);saving.undo();saving.redo()
let blocked=saving.preview == operation.changes && saving.changeRevision == beforeSave.changeRevision
var foreign=HexEditSession();foreign.editRow(Array(repeating:"01",count:16).joined(separator:" "),data:data,baseOffset:0,row:0);let foreignOperation=foreign.beginSave()!
let foreignRejected = !saving.markSaved(foreignOperation)
let wrongChanges=HexSaveOperation(id:operation.id,changes:[HexByteChange(offset:0,oldValue:0,newValue:2)])
let wrongChangesRejected = !saving.markSaved(wrongChanges)
saving.markSaveFailed(foreignOperation,message:"foreign");let foreignFailureIgnored=saving.isSaving && saving.saveErrorMessage == nil
saving.markSaveFailed(operation,message:"expected failure");let failedKeepsChanges = saving.hasChanges && !saving.isSaving && saving.canUndo && saving.saveErrorMessage != nil
let successful=saving.beginSave()!;let success=saving.markSaved(successful)
let saveLineage:[String:Any]=["begin_changes_lineage":!beforeSave.hasSameEditingLineage(as:duringSave),"blocked_while_saving":blocked,"foreign_success_rejected":foreignRejected,"same_id_wrong_changes_rejected":wrongChangesRejected,"foreign_failure_ignored":foreignFailureIgnored,"failed_keeps_changes_and_history":failedKeepsChanges,"success_clears_changes_and_history":success && !saving.hasChanges && !saving.canUndo && !saving.canRedo && !saving.isSaving,"success_changes_lineage":!saving.hasSameEditingLineage(as:duringSave),"duplicate_success_rejected":!saving.markSaved(successful)]
precondition(saveLineage.values.allSatisfy{($0 as? Bool)==true})
let applying:[String:Any]=["empty":HexEditing.applying([:],to:Data())!.map(Int.init),"valid":HexEditing.applying([0:255,2:0],to:Data([1,2,3]))!.map(Int.init),"out_of_bounds_rejected":HexEditing.applying([3:0],to:Data([1,2,3]))==nil,"maximum_offset_rejected":HexEditing.applying([UInt64.max:0],to:Data([1,2,3]))==nil]
let result:[String:Any]=["parse":parseCases,"sessions":scenarios,"saveLineage":saveLineage,"applying":applying]
print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)

import Foundation
var points:[UInt32]=[]
var whitespace:[UInt32]=[]
var extendable:[UInt32]=[]
var prefixAccepted:[UInt32]=[]
for n:UInt32 in 0...0x10ffff {
 guard let scalar=UnicodeScalar(n)else{continue}
 let value=String(scalar)
 if Character(value).isWhitespace {whitespace.append(n);let joined=value+"\u{301}";if joined.count==1 && joined.first!.isWhitespace{extendable.append(n)}}
 let suffix=" "+value
 if suffix.count==1 && suffix.first!.isWhitespace {points.append(n)}
 let prefix=value+" "
 if !Character(value).isWhitespace && prefix.count==1 && prefix.first!.isWhitespace{prefixAccepted.append(n)}
}
var ranges:[[UInt32]]=[]
for n in points {if let last=ranges.last,last[1]+1==n {ranges[ranges.count-1][1]=n}else{ranges.append([n,n])}}
let output:[String:Any]=["swift":"6.2.1","whitespace":whitespace,"extendable_whitespace":extendable,"whitespace_suffix_ranges":ranges,"non_whitespace_prefixes_accepted":prefixAccepted,"scalar_count":0x110000-0x800]
print(String(data:try! JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)

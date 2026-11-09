var $worker : 4D.SystemWorker
var $status : Text
$worker:=4D.SystemWorker.new("/bin/sh")
$worker.postMessage("test ! -e /test && test ! -e /shell-engine-source && test -f /output/input.4dm && printf shell-isolated")
$worker.closeInput()
$worker.wait(1000)
$status:="FEHLER Shell isolation check failed"
If (($worker.exitCode=0) & ($worker.response="shell-isolated"))
File("/output/output.4dm"; fk posix path).setText("// shell-isolated"+Char(10)+"// caller: "+Current system user)
$status:="OK"
End if
File("/output/output.4dm.status"; fk posix path).setText($status)
QUIT 4D

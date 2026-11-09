#!/usr/bin/env python3
import gi,json,resource,time,sys,ctypes,struct,zlib
for name,version in [('Gtk','4.0'),('GtkSource','5'),('GdkX11','4.0')]:gi.require_version(name,version)
from gi.repository import Gtk,GtkSource,GLib,Gdk,GdkX11
Gtk.init();GtkSource.init()
checks=[];metrics=[]
def check(name,value):
    if not value:raise AssertionError(name)
    checks.append(name)
def text(buffer):return buffer.get_text(*buffer.get_bounds(),True)
buffer=GtkSource.Buffer();buffer.set_enable_undo(True)
a=GtkSource.View(buffer=buffer);b=GtkSource.View(buffer=buffer)
for v in [a,b]:v.set_monospace(True);v.set_wrap_mode(Gtk.WrapMode.WORD_CHAR);v.set_show_line_numbers(True)
box=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
for v in [a,b]:
    scroller=Gtk.ScrolledWindow();scroller.set_child(v);scroller.set_hexpand(True);box.append(scroller)
win=Gtk.Window(title='Fastra F01 — isolierte Editorprobe',default_width=900,default_height=500);win.set_child(box);win.present()
def drain():
    context=GLib.MainContext.default()
    deadline=time.monotonic()+.15
    while time.monotonic()<deadline:
        if context.pending():context.iteration(False)
        else:time.sleep(.005)
drain()
for size in ([] if '--snapshot-only' in sys.argv else [4*1024*1024,32*1024*1024]):
    content=('alpha\t CRLF\r\n'*(size//13+1))[:size]
    start=time.monotonic();buffer.set_text(content);drain()
    metrics.append({'requested_characters':size,'utf8_bytes':len(content.encode()),'load_seconds':round(time.monotonic()-start,4),'max_rss_kib':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
    check(f'complete buffer {size}',text(buffer)==content)
    check(f'shared buffer {size}',a.get_buffer()==b.get_buffer())
# Die Größenwerte messen bewusst Bytes, nicht irrtümlich Zeichen als MiB.
for byte_size in ([] if '--snapshot-only' in sys.argv else [4*1024*1024,32*1024*1024]):
    content='a'*(byte_size-1)+'\n';start=time.monotonic();buffer.set_text(content);drain()
    metrics.append({'ascii_bytes':byte_size,'single_line':True,'load_seconds':round(time.monotonic()-start,4),'max_rss_kib':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})
    check(f'long line byte count {byte_size}',len(text(buffer).encode())==byte_size)
baseline='e\u0301 😀\t\r\nshort\r\nlast\n';buffer.set_text(baseline)
buffer.begin_user_action();buffer.insert(buffer.get_start_iter(),'one ');buffer.insert(buffer.get_end_iter(),'two');buffer.end_user_action()
check('both edits visible in shared view',text(b.get_buffer())=='one '+baseline+'two')
buffer.undo();check('one undo per multiple operation',text(buffer)==baseline)
buffer.redo();check('redo preserves Unicode CRLF and tabs',text(buffer)=='one '+baseline+'two')
manager=GtkSource.LanguageManager.get_default();buffer.set_language(manager.get_language('python'));buffer.set_text('# comment\nprint(2)\n')
buffer.ensure_highlight(*buffer.get_bounds());drain();check('real source highlighter context','comment' in buffer.get_context_classes_at_iter(buffer.get_start_iter()))
# GTK bietet genau ein natives Auswahlpaar, weitere Cursor brauchen einen Adapter.
buffer.select_range(buffer.get_iter_at_offset(0),buffer.get_iter_at_offset(3));buffer.select_range(buffer.get_iter_at_offset(10),buffer.get_iter_at_offset(15))
r=buffer.get_selection_bounds();check('native selection is one range',len(r)==2 and r[0].get_offset()==10)
drain()
if isinstance(win.get_surface(),GdkX11.X11Surface):
    class XImage(ctypes.Structure):
        _fields_=[('width',ctypes.c_int),('height',ctypes.c_int),('xoffset',ctypes.c_int),('format',ctypes.c_int),('data',ctypes.c_void_p),('byte_order',ctypes.c_int),('bitmap_unit',ctypes.c_int),('bitmap_bit_order',ctypes.c_int),('bitmap_pad',ctypes.c_int),('depth',ctypes.c_int),('bytes_per_line',ctypes.c_int),('bits_per_pixel',ctypes.c_int),('red_mask',ctypes.c_ulong),('green_mask',ctypes.c_ulong),('blue_mask',ctypes.c_ulong)]
    lib=ctypes.CDLL('libX11.so.6');lib.XOpenDisplay.argtypes=[ctypes.c_char_p];lib.XOpenDisplay.restype=ctypes.c_void_p
    lib.XGetImage.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint,ctypes.c_ulong,ctypes.c_int];lib.XGetImage.restype=ctypes.POINTER(XImage)
    lib.XDestroyImage.argtypes=[ctypes.POINTER(XImage)];lib.XCloseDisplay.argtypes=[ctypes.c_void_p]
    display=lib.XOpenDisplay(None);image=lib.XGetImage(display,win.get_surface().get_xid(),0,0,win.get_width(),win.get_height(),ctypes.c_ulong(-1),2)
    info=image.contents;pixels=ctypes.string_at(info.data,info.bytes_per_line*info.height)
    check('X11 screenshot format',info.bits_per_pixel==32 and info.byte_order==0 and info.red_mask==0xff0000 and info.green_mask==0xff00 and info.blue_mask==0xff)
    rows=[]
    for y in range(info.height):
        row=bytearray([0])
        for x in range(info.width):
            offset=y*info.bytes_per_line+x*4;row.extend([pixels[offset+2],pixels[offset+1],pixels[offset]])
        rows.append(row)
    def chunk(kind,payload):return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',info.width,info.height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b'')
    with open(sys.argv[1],'wb') as handle:handle.write(png)
    lib.XDestroyImage(image);lib.XCloseDisplay(display);checks.append('actual X11 window PNG')
print(json.dumps({'gtk':f'{Gtk.get_major_version()}.{Gtk.get_minor_version()}.{Gtk.get_micro_version()}','source':f'{GtkSource.get_major_version()}.{GtkSource.get_minor_version()}.{GtkSource.get_micro_version()}','backend':Gdk.Display.get_default().get_name(),'checks':checks,'metrics':metrics,'not_tested':['logical rectangle adapter','folding adapter','IME','physical German keyboard','capture drag','real desktop accessibility and fractional scale']},indent=2))
win.destroy()

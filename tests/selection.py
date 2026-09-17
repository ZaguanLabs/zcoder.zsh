"""Real encoded mouse events through zcoder's shared terminal reader."""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
runtime = Path((ROOT / '.build/native/current').read_text().strip())

def run(profile='auto', backend='auto', markdown='auto', selection='auto'):
    control_r, control_w = os.pipe()
    report_r, report_w = os.pipe()
    pid, terminal = pty.fork()
    if pid == 0:
        os.close(control_w); os.close(report_r)
        os.set_inheritable(control_r, True); os.set_inheritable(report_w, True)
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 92, 0, 0))
        os.environ.update(TERM='xterm-256color', LC_ALL='C.UTF-8', ZCODER_COLOR=profile, NO_COLOR='')
        os.environ.update(ZCODER_MARKDOWN=markdown, ZCODER_MOUSE_SELECTION=selection)
        os.environ.pop('LINES', None); os.environ.pop('COLUMNS', None)
        os.execl(str(runtime/'bin/zsh'), 'zsh', '-df', str(ROOT/'scripts/run-native.zsh'),
                 str(ROOT/'tests/fixtures/selection_ui.zsh'), str(runtime), str(ROOT),
                 str(report_w), str(control_r), backend)
    os.close(control_r); os.close(report_w)
    pending=bytearray(); screen=bytearray(); reaped=False
    def report():
        deadline=time.monotonic()+10
        while b'\n' not in pending:
            assert time.monotonic()<deadline, screen[-6000:]
            for fd in select.select([report_r,terminal],[],[],.1)[0]:
                data=os.read(fd,65536)
                if fd==report_r:
                    assert data, screen[-6000:]
                    pending.extend(data)
                else: screen.extend(data)
        line,_,rest=pending.partition(b'\n'); pending[:]=rest
        return json.loads(line)
    def step(data=b'', command='read'):
        if data: os.write(terminal,data)
        os.write(control_w,(command+'\n').encode())
        return report()
    def mouse(x,y,code=0,release=False):
        return step(f'\x1b[<{code};{x+1};{y+1}{"m" if release else "M"}'.encode())
    try:
        initial=report()
        if backend=='stock' or selection=='false':
            assert initial['enabled']==0
        else:
            assert initial['enabled']==1, initial
            baseline=step(command='snapshot')
            step() # mouse reporting enabled by the first read
            content=[r for r in initial['rows'] if r['col']>=0 and r['text']]
            first=content[0]; x=initial['side']+1+first['col']; y=first['y']
            a=mouse(x,y); assert a['selected']==1, a
            a=mouse(91,22,32); assert a['active']==1, a
            a=mouse(91,22,release=True); assert a['active']==0 and a['selected']==1, a
            assert a['text'].startswith('Alpha beta gamma delta epsilon'), repr(a['text'])
            assert 'mu nu xi omicron' in a['text'], repr(a['text'])
            assert '  print -r -- "hello"\n    next line' in a['text'], repr(a['text'])
            assert 'Wide 界 combining é emoji 👩‍💻.' in a['text'], repr(a['text'])
            assert 'Assistant' not in a['text'] and 'zsh' not in a['text']
            highlighted=step(command='snapshot')
            assert highlighted['side_win']==baseline['side_win']
            assert highlighted['input_win']==baseline['input_win']
            assert highlighted['chat_win']!=baseline['chat_win']
            # Every border cell remains byte/style identical.
            h=int(baseline['chat_win']['rows']); w=int(baseline['chat_win']['columns'])
            for key,value in baseline['chat_win'].items():
                parts=key.split(',')
                if len(parts)>=3 and parts[0].isdigit() and parts[1].isdigit():
                    if int(parts[0]) in (0,h-1) or int(parts[1]) in (0,w-1):
                        assert highlighted['chat_win'][key]==value, key
            copied=a['text']
            a=step(b'\x1b'); assert a['selected']==0
            restored=step(command='snapshot')
            assert restored['chat_win']==baseline['chat_win'], 'clearing changed base styles'
            mouse(x,y); mouse(91,22,32); mouse(91,22,release=True)
            a=step(command='append'); assert a['text']==copied
            a=step(b'\x19'); assert a['text']==copied
            encoded=base64.b64encode(copied.encode())
            # Drain terminal output emitted before the next control rendezvous.
            for _ in range(10):
                if select.select([terminal],[],[],.05)[0]: screen.extend(os.read(terminal,65536))
            assert b'\x1b]52;c;'+encoded+b'\x07' in screen, screen[-4000:]
            a=step(b'\x1b'); assert a['selected']==0, a
            assert any('New streaming output.' in r['text'] for r in a['rows'])
            # Starting in the sidebar and moving into text cannot select it.
            mouse(1,y); a=mouse(x+2,y,32); assert a['selected']==0
            mouse(x+2,y,release=True)
            a=mouse(x,y); assert a['selected']==1
            a=step(command='scroll'); assert a['selected']==0
            mouse(1,y,release=True)
            a=step(command='reset')
            # A modal opening mid-drag cancels and drains the owned release.
            mouse(x,y); mouse(x+4,y,32)
            a=step(f'\x1b[<0;{x+1};{y+1}mq'.encode(), 'modal')
            assert a['selected']==0 and a['active']==0, a
            # Reverse selection, then geometry invalidation through SIGWINCH.
            mouse(x+5,y); a=mouse(x,y,32); a=mouse(x,y,release=True)
            assert a['text']=='Alpha ', repr(a['text'])
            a=step(b'\x1b','activity')
            # A selection owns Escape before active-work cancellation sees it.
            for _ in range(20):
                if not a['selected']: break
                time.sleep(.02); a=step(command='activity')
            assert a['selected']==0 and a['activity_result']==0, a
            a=step(b'\x1b','activity')
            for _ in range(20):
                if a['activity_result']: break
                time.sleep(.02); a=step(command='activity')
            assert a['activity_result']==130, a
            a=step(command='diff')
            diff_rows=[r for r in a['rows'] if r['text']=='old text' and r['col']>=0]
            assert len(diff_rows)==1, a['rows']
            d=diff_rows[0]
            mouse(a['side']+1+d['col'],d['y'])
            mouse(91,22,32); a=mouse(91,22,release=True)
            assert a['text']=='old text\nnew text\ncontext', repr(a['text'])
            a=step(command='code')
            rows=[r for r in a['rows'] if r['col']>=0]
            logical=''.join((r['gap'] if n else '')+r['text'] for n,r in enumerate(rows))
            assert logical.strip('\n')=='x'*5000+'\n界    X    Y', repr(logical[-100:])
            fcntl.ioctl(terminal,termios.TIOCSWINSZ,struct.pack('HHHH',20,60,0,0))
            os.kill(pid,signal.SIGWINCH)
            a=step(); assert a['selected']==0 and a['width']==60, a
        os.write(control_w,b'quit\n')
        _,status=os.waitpid(pid,0); reaped=True
        assert os.waitstatus_to_exitcode(status)==0, screen[-4000:]
        print(f'PASS: selection {backend}/{profile}, Markdown={markdown}, selection={selection}')
    finally:
        if not reaped:
            os.kill(pid,signal.SIGKILL); os.waitpid(pid,0)
        for fd in (control_w,report_r,terminal): os.close(fd)

if __name__=='__main__':
    run(); run('mono'); run(markdown='zsh'); run(backend='stock'); run(selection='false')

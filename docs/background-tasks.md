# Background commands

In the local TUI, the model can call `run_command` with `background: true` for
a long build, test suite, or other command. The usual workspace, safety, and
command approval checks apply before anything starts. The tool returns a task
ID immediately. You can continue chatting and working while the command runs.

The footer shows running tasks and results awaiting follow-up. `/tasks` lists
them; `/tasks cancel task-1` stops a task and queues its partial output as a
cancelled result. Escape still stops the foreground operation.

Completion does not interrupt a model request, tool sequence, or queued user
follow-up. After the entire foreground turn returns to the idle loop, zcoder
delivers the result and starts a follow-up. When already idle, it does so
automatically. There are no model requests just to check task progress.
Results are delivered once, in their original conversation. If you switch
conversations, they wait until you return.

Tasks belong to the running zcoder process. Quitting cancels them. Workers also
watch for parent loss and terminate their process group if zcoder crashes,
including on SIGKILL. Commands must not daemonize or move themselves into a
different session/process group. Completed side effects cannot be rolled back.
Tasks and completion notifications are not restored after restarting zcoder.

Background commands default to a 24-hour timeout and accept `timeout_seconds`
from 1 through 86400. Foreground commands retain their 120-second default and
3600-second maximum. Output is collected with the existing bounded head/tail
reader. Up to 32 running or undelivered tasks can be owned at once.

This initial implementation supports the local TUI. Remote clients, headless
servers, ACP, and one-shot invocations do not advertise background execution
and reject requests to use it.

# User shell commands

Start a message with `!` to run a shell command and display its output in chat:

```text
! ls -l
! git status --short
! make test
```

The command runs through the existing `run_command` approval policy. Results
show the command, working directory, exit status, and combined stdout/stderr.
The agent does not respond automatically, even if the command fails. Your
next ordinary request receives the captured result as conversation context:

```text
! make test
What caused those failures?
```

Commands run in a separate Zsh process rooted at the selected workspace.
Shell syntax such as pipes, redirections, and command substitution works.
Changing directory or exporting a variable affects that command's process;
it does not change the workspace or environment for later commands. Use, for
example, `! cd src && ls` for a command in a subdirectory.

Command output uses the existing tool-output limit, retaining its beginning
and end with an omission marker for large results. Captured results persist
with saved sessions and are subject to normal context compaction. Avoid
printing information you do not want in the conversation.

During active work, `!` commands wait until the current task finishes. Later
requests wait behind the command so they can use its output. A command by
itself never starts another model response. Escape cancels a running command;
completed side effects remain. Pending commands can be inspected or discarded
with `/queue`, `/queue resume`, and `/queue drop MESSAGE_ID` as described in
[queued input](queued-input.md). Recovery never automatically repeats a
command whose execution was already claimed but whose result was not saved.

The same behavior applies to local terminal input, `--prompt`, remote HTTP
turns, and ACP prompts. When connected to a server, commands run on that
server in its selected workspace. ACP clients receive output through the
existing tool-call lifecycle. A bare `!` displays usage help.

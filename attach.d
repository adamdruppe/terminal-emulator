module arsd.terminalemulatorattachutility;

import arsd.detachableterminalemulatormessage;

import terminal;

// dmd attach.d message.d ~/arsd/terminal.d ~/d/dmd2/src/phobos/std/socket.d

/*
	FIXME: make rebindable escape character

	Working with sessions:
	attach -S foo # opens a session called foo

	A session is a collection of screens. Any new screens created here will be added to the session.

	or maybe C-a c means create temporary.
	C-a C means create permanent. Permanent screens get a proper name and are added to the session.

	C-a D means detach current screen only
	C-a d detaches the whole session
*/

/*
	The attach program should provide the UI and other stuff.
	So if you attach to two things at once, this will ignore the inactive
	sockets and when you switch to one, it requests a redraw from the new one
	and changes its ignore flag.

	Attach sessions can be little files in with the sockets that tells it what
	ones are wanted. Attaching to a file grabs all the tabs at once.

	./attach foo bar baz # gets foo as screen 0, bar as screen 1, baz as 2.
	./attach te # grabs te, which may be a session file that refers to several things.


	If a thing doesn't exist, it should spawn a detchableterminalemulator automatically.
*/

static import core.stdc.stdlib;
import std.conv;
import std.socket;
struct ChildTerminal {
	Socket socket;
	string title;

	string socketName;
	// tab image

	// for mouse click detection
	int x;
	int x2;
}

extern(C) nothrow static @nogc
void detachable_child_dead(int) {
	import core.sys.posix.sys.wait;
	wait(null);
}

void main(string[] args) {
	bool debugMode;

	string[] snames;
	if(args.length > 1) {
		foreach(arg; args[1 .. $])
			snames ~= arg;
	} else {
		// list the available sockets...
		import std.file, std.process, std.stdio;
		bool found = false;
		auto dirName = environment["HOME"] ~ "/.detachable-terminals";
		foreach(string name; dirEntries(dirName, SpanMode.shallow)) {
			writeln(name[dirName.length + 1 .. $]);
			found = true;
		}
		if(!found)
			writeln("No screens found");
		return;
	}

	import core.sys.posix.signal;
	signal(SIGPIPE, SIG_IGN);
	signal(SIGCHLD, &detachable_child_dead);

	import std.process;
	ChildTerminal[] children;
	foreach(idx, sname; snames) {
		auto socket = connectTo(sname);
		if(socket is null)
			sname = "[failed]";
		children ~= ChildTerminal(socket, sname, sname);

		// we should scan inactive sockets for:
		// 1) a bell
		// 2) a title change
		// 3) a window icon change

		// as these can all be reflected in the tab listing
	}

	if(children.length == 0)
		return;

	// doing these just to get it in the state i want
	auto terminal = Terminal(ConsoleOutputType.cellular);
	auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);

	Socket socket;

	// then all we do is forward data to/from stdin to the pipe
	import core.stdc.errno;
	import core.sys.posix.unistd;
	import core.sys.posix.sys.select;

	bool escaping;
	int activeScreen = 0;
	int previousScreen = 0;
	bool showingTaskbar = true;

	void setActiveScreen(int s, bool force = false) {
		if(s < 0 || s >= children.length)
			return;
		if(children[s].socket is socket && !force)
			return; // already active
		if(children[s].socket is null)
			return; // vacant slot cannot be activated

		previousScreen = activeScreen;
		activeScreen = s;

		terminal.clear();

		int spaceRemaining = terminal.width;
		if(showingTaskbar) {
			terminal.moveTo(0, terminal.height - 1);
			//terminal.writeStringRaw("\033[K"); // clear line
			terminal.color(Color.DEFAULT, Color.DEFAULT, ForceOption.alwaysSend, true);
			terminal.write("+ ");
			spaceRemaining-=2;
			spaceRemaining--; // save space for the close button on the end
		}

		socket = children[s].socket;

		if(showingTaskbar) {
			foreach(idx, ref child; children) {
				child.x = terminal.width - spaceRemaining - 1;
				terminal.color(Color.DEFAULT, Color.DEFAULT, ForceOption.automatic, idx != s);
				terminal.write(" ");
				spaceRemaining--;

				int size = 12;
				if(spaceRemaining < size)
					size = spaceRemaining;
				if(size <= 2)
					break;

				if(child.title.length == 0)
					child.title = "Screen " ~ to!string(idx + 1);

				if(child.title.length <= size-2) {
					terminal.write(child.title);
					foreach(i; child.title.length .. size-2)
						terminal.write(" ");
				} else {
					terminal.write(child.title[0 .. size-2]);
				}
				terminal.write("  ");
				spaceRemaining -= size;
				child.x2 = terminal.width - spaceRemaining - 1;
				if(spaceRemaining == 0)
					break;
			}
			terminal.color(Color.DEFAULT, Color.DEFAULT, ForceOption.automatic, true);

			foreach(i; 0 .. spaceRemaining)
				terminal.write(" ");
			terminal.write("X");
		}

		// force the size
		{
			InputMessage im;
			im.eventLength = im.sizeof;
			im.sizeEvent.width = terminal.width;
			im.sizeEvent.height = terminal.height - (showingTaskbar ? 1 : 0);
			im.type = InputMessage.Type.SizeChanged;
			write(socket.handle, &im, im.eventLength);
		}

		// and force a redraw
		{
			InputMessage im;
			im.eventLength = im.sizeof;
			im.type = InputMessage.Type.RedrawNow;
			write(socket.handle, &im, im.eventLength);
		}
	}

	foreach(idx, child; children)
		if(child.socket !is null) {
			setActiveScreen(idx, true);
			break;
		}
	if(socket is null)
		return;

	bool running = true;

	void closeSocket(Socket socketToClose = null) {
		if(socketToClose is null)
			socketToClose = socket;
		assert(socketToClose !is null);

		int switchTo = -1;
		foreach(idx, ref child; children) {
			if(child.socket is socketToClose) {
				child.socket = null;
				child.title = "[vacant]";
				switchTo = previousScreen;
				import std.stdio; writeln("closing ", idx);
				break;
			}
		}

		socketToClose.shutdown(SocketShutdown.BOTH);
		socketToClose.close();

		if(socketToClose !is socket) {
			setActiveScreen(activeScreen, true); // redraw the taskbar
			return; // no need to close; it isn't the active socket
		}

		socket = null;

		if(switchTo >= children.length)
			switchTo = 0;

		foreach(s; switchTo .. children.length)
			if(children[s].socket !is null) {
				switchTo = s;
				goto allSet;
			}
		foreach(s; 0 .. switchTo)
			if(children[s].socket !is null) {
				switchTo = s;
				goto allSet;
			}

		switchTo = -1;

		allSet:

		if(switchTo < 0 || switchTo >= children.length) {
			running = false;
			socket = null;
			return;
		} else if(children[switchTo].socket is null) {
			running = false;
			socket = null;
			return;
		}
		setActiveScreen(switchTo, true);
	}

	int commandLinePosition = -1;
	dchar[256] commandLineBuffer;
	dchar[] commandLine = commandLineBuffer[];

	void handleEvent(InputEvent event) {
		// FIXME: UI stuff

		InputMessage im;
		im.eventLength = im.sizeof;
		InputMessage* eventToSend;
		final switch(event.type) {
			case InputEvent.Type.CharacterEvent:
				auto ce = event.get!(InputEvent.Type.CharacterEvent);
				if(ce.eventType == CharacterEvent.Type.Released)
					return;

				if(commandLinePosition >= 0) {
					switch(ce.character) {
						case 10:
							auto cmdLine = commandLine[0 .. commandLinePosition];
							commandLinePosition = -1;
							setActiveScreen(activeScreen, true); // get the app to redraw
							terminal.write(cmdLine);
						break;
						case 8:
							if(commandLinePosition)
								commandLinePosition--;
							terminal.write(ce.character);
						break;
						default:
							if(commandLinePosition >= commandLine.length)
								commandLine.length = commandLine.length * 2;

							commandLine[commandLinePosition++] = ce.character;
							terminal.write(ce.character);
					}

					return;
				}

				if(escaping) {
					if(ce.character == 1) {
						if(previousScreen != activeScreen)
							setActiveScreen(previousScreen);
						else {
							auto n = activeScreen + 1;
							if(n >= children.length)
								n = 0;
							setActiveScreen(n);
						}
					} else
					switch(ce.character) {
						case 'q': debugMode = !debugMode; break;
						case 't':
							showingTaskbar = !showingTaskbar;
							setActiveScreen(activeScreen, true);
						break;
						case ' ':
							setActiveScreen(activeScreen + 1);
						break;
						case 'd':
							running = false;
						break;
						case ':':
							terminal.moveTo(0, terminal.height - 1);
							terminal.color(Color.DEFAULT, Color.DEFAULT, ForceOption.alwaysSend, true);
							terminal.write(": ");
							foreach(i; 2 .. terminal.width)
								terminal.write(" ");
							terminal.moveTo(2, terminal.height - 1);
							commandLinePosition = 0;
						break;
						case 'c':
							int position = -1;
							foreach(idx, child; children)
								if(child.socket is null) {
									position = idx;
									break;
								}
							if(position == -1) {
								position = children.length;
								children ~= ChildTerminal();
							}

							import core.stdc.time;
							string sname = "anonymous-" ~ to!string(time(null));
							// spin off the child process

							auto newSocket = connectTo(sname);
							if(newSocket) {
								children[position] = ChildTerminal(newSocket, sname, sname);
								setActiveScreen(position);
							}
						break;
						case '0':
						..
						case '9':
							int num = cast(int) (ce.character - '0');
							if(num == 0)
								num = 9;
							else
								num--;
							setActiveScreen(num);
						break;
						default:
					}
					escaping = false;
					return;
				} else if(ce.character == 1) {
					escaping = true;
					return;
				}

				im.type = InputMessage.Type.CharacterPressed;
				im.characterEvent.character = ce.character;
				eventToSend = &im;
			break;
			case InputEvent.Type.SizeChangedEvent:
				/*
				auto ce = event.get!(InputEvent.Type.SizeChangedEvent);
				im.type = InputMessage.Type.SizeChanged;
				im.sizeEvent.width = ce.newWidth;
				im.sizeEvent.height = ce.newHeight - (showingTaskbar ? 1 : 0);
				eventToSend = &im;
				*/
				setActiveScreen(activeScreen, true);
			break;
			case InputEvent.Type.UserInterruptionEvent:
				im.type = InputMessage.Type.CharacterPressed;
				im.characterEvent.character = '\003';
				eventToSend = &im;
				//running = false;
			break;
			case InputEvent.Type.NonCharacterKeyEvent:
				auto ev = event.get!(InputEvent.Type.NonCharacterKeyEvent);
				if(ev.eventType == NonCharacterKeyEvent.Type.Pressed) {

					if(escaping) {
						switch(ev.key) {
							case NonCharacterKeyEvent.Key.LeftArrow:
								setActiveScreen(activeScreen - 1);
							break;
							case NonCharacterKeyEvent.Key.RightArrow:
								setActiveScreen(activeScreen + 1);
							break;
							default:
						}
						//escaping = false;
						// staying in escape mode so you can cycle with arrows more easily. hit enter to go back to normal mode
						return;
					}

					im.type = InputMessage.Type.KeyPressed;

					im.keyEvent.key = cast(int) ev.key; // this can be casted to a TerminalKey later
					im.keyEvent.modifiers = 0;
					if(ev.modifierState & ModifierState.shift)
						im.keyEvent.modifiers |= InputMessage.Shift;
					if(ev.modifierState & ModifierState.control)
						im.keyEvent.modifiers |= InputMessage.Ctrl;
					if(ev.modifierState & ModifierState.alt)
						im.keyEvent.modifiers |= InputMessage.Alt;
					eventToSend = &im;
				}
			break;
			case InputEvent.Type.PasteEvent:
				auto ev = event.get!(InputEvent.Type.PasteEvent);
				assert(0);
				//sendPasteData(ev.pastedText);
				// FIXME
			break;
			case InputEvent.Type.MouseEvent:
				auto me = event.get!(InputEvent.Type.MouseEvent);

				if(showingTaskbar && me.y == terminal.height - 1) {
					if(me.eventType == MouseEvent.Type.Pressed)
						foreach(idx, child; children) {
							if(me.x >= child.x && me.x < child.x2) {
								if(socket !is children[idx].socket)
									setActiveScreen(idx);
								break;
							}
						}
					return;
				}

				final switch(me.eventType) {
					case MouseEvent.Type.Moved:
						im.type = InputMessage.Type.MouseMoved;
					break;
					case MouseEvent.Type.Pressed:
						im.type = InputMessage.Type.MousePressed;
					break;
					case MouseEvent.Type.Released:
						im.type = InputMessage.Type.MouseReleased;
					break;
					case MouseEvent.Type.Clicked:
						// FIXME
				}

				eventToSend = &im;

				im.mouseEvent.x = me.x;
				im.mouseEvent.y = me.y;
				im.mouseEvent.button = cast(int) me.buttons;
				im.mouseEvent.modifiers = 0;
				if(me.modifierState & ModifierState.shift)
					im.mouseEvent.modifiers |= InputMessage.Shift;
				if(me.modifierState & ModifierState.control)
					im.mouseEvent.modifiers |= InputMessage.Ctrl;
				if(me.modifierState & ModifierState.alt)
					im.mouseEvent.modifiers |= InputMessage.Alt;
			break;
			case InputEvent.Type.CustomEvent:
			break;

		}

		if(eventToSend !is null && socket !is null) {
			auto len = write(socket.handle, eventToSend, eventToSend.eventLength);
			if(len <= 0) {
				closeSocket();
			}
		}
	}

	while(running) {
		terminal.flush();
		ubyte[4096] buffer;
		fd_set rdfs;
		FD_ZERO(&rdfs);

		FD_SET(0, &rdfs);
		int maxFd = 0;
		foreach(child; children) {
			if(child.socket !is null) {
				FD_SET(child.socket.handle, &rdfs);
				if(child.socket.handle > maxFd)
					maxFd = child.socket.handle;
			}
		}

		auto ret = select(maxFd + 1, &rdfs, null, null, null);
		if(ret == -1) {
			if(errno == 4) {
				// FIXME: check interrupted and size event
				while(running && (interrupted || windowSizeChanged))
					handleEvent(input.nextEvent());
				continue; // EINTR
			}
			else throw new Exception("select");
		}

		if(ret) {
			if(FD_ISSET(0, &rdfs)) {
				// the terminal is ready, we'll call next event here
				handleEvent(input.nextEvent());
			}

			foreach(child; children) {
				if(child.socket !is null)
				if(FD_ISSET(child.socket.handle, &rdfs)) {
					// data from the pty should be forwarded straight out
					int len = read(child.socket.handle, buffer.ptr, buffer.length);
					if(len <= 0) {
						// probably end of file or something cuz the child exited
						// we should switch to the next possible screen
						// throw new Exception("closing cuz of bad read " ~ to!string(errno));
						closeSocket(child.socket);

						continue;
					}

					if(child.socket is socket) {
						auto toWrite = buffer[0 .. len];
						while(len) {
							if(!debugMode) {
								auto wrote = write(1, toWrite.ptr, len);
								if(wrote <= 0)
									throw new Exception("write");
								toWrite = toWrite[wrote .. $];
								len -= wrote;
							} else {import std.stdio; writeln(to!string(buffer[0..len])); len = 0;}
						}
					}
				}
			}
		}
	}
}


Socket connectTo(string sname, bool spawn = true) {
	import std.process;
	auto socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
	try {
		socket.connect(new UnixAddress(environment["HOME"] ~ "/.detachable-terminals/" ~ sname));
	} catch(Exception e) {
		// if it can't connect, we'll spawn a new backend to control it

		// import std.stdio; writeln(e); return null;
		socket = null;

		if(spawn) {
			import core.sys.posix.unistd;
			if(auto pid = fork()) {
				int tries = 3;
				while(tries > 0 && socket is null) {
					// give the child a chance to get started...
					import core.thread;
					Thread.sleep(dur!"msecs"(25));

					// and try to connect
					auto newSocket = connectTo(sname, false);
					if(newSocket is null)
						sname = "[failed]";

					socket = newSocket;
					tries--;
				}
			} else {
				// child

				import core.sys.posix.fcntl;
				auto n = open("/dev/null", O_RDONLY);
				auto n2 = open("/dev/null", O_WRONLY);
				assert(n >= 0);
				import core.stdc.errno;
				assert(n2 >= 0, to!string(errno));
				dup2(n, 0);
				dup2(n2, 1);

				// also detach from the calling foreground process group
				// because otherwise SIGINT will be sent to this too and kill
				// it instead of just going to the parent and being translated
				// into a ctrl+c input for the child.

				setpgid(0, 0);

				if(true) {
					// and run the detachable backend now

					{
					// If we don't do this, events will get mixed up because
					// the pipes handles would be inherited across fork.
					import arsd.eventloop;
					openNewEventPipes();
					}


					// also changing the command line as seen in the shell ps command
					import core.runtime;
					auto cArgs = Runtime.cArgs;
					if(cArgs.argc) {
						import core.stdc.string;
						auto toOverwritePtr = cArgs.argv[0];
						auto toOverwrite = toOverwritePtr[0 .. strlen(toOverwritePtr)];
						toOverwrite[] = 0;
						auto newName = "ATTACH";
						if(newName.length > toOverwrite.length - 1)
							newName = newName[0 .. toOverwrite.length - 1]; // leave room for a 0 terminator
						toOverwrite[0 .. newName.length] = newName[];
					}

					// and calling main
					import arsd.detachableterminalemulator;
					try {
						detachableMain(["ATTACH", sname]);
					} catch(Throwable t) {

					}

					core.stdc.stdlib.exit(0); // we want this process dead like it would be with exec()
				}

				// alternatively, but this requires a separate binary:
				// compile it separately with -version=standalone_detachable if you want it (is better for debugging btw) then use this code
				/*
				auto proggie = "/home/me/program/terminal-emulator/detachable";
				if(execl(proggie.ptr, proggie.ptr, (sname ~ "\0").ptr, 0))
					throw new Exception("wtf " ~ to!string(errno));
				*/
			}
		}
	}
	return socket;
}



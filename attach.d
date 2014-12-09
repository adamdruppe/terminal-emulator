/++
	This is a GNU Screen style program to multiplex and provide remote attach/detach
	support to a terminal emulator backend.

	It works with two pieces: sessions and screens. A session is a collection of screens
	and a screen is one backend terminal emulator.

	attach must be run inside a terminal emulator itself. For best results, use the GUI
	frontend provided in this package, but it will also work on most others like the linux
	console or xterm. You can also use a nested terminal emulator with it if you want.

	Controls by default are based on screen. Differences are:

	C-a D: detach the current screen from the session
	C-a C: attach a specific screen to the session

	C-a t: toggle taskbar. The taskbar will show a tab in green if it has a beep.

	C-a <colon>: start command line
		attach socket_name

	You can edit session files in ~/.detachable-terminals with a text editor.
+/
module arsd.terminalemulatorattachutility;

import arsd.detachableterminalemulatormessage;

import terminal;

static import std.file;
static import core.stdc.stdlib;
import std.conv;
import std.socket;

/*
	FIXME: error messages aren't displayed when you attach and the socket cannot be opened
	FIXME: SIGSTOP should be propagated too.

	Session file example:

	title: foo
	icon: bar.png
	cwd: /home/me
	screens: foo bar baz

	FIXME: support icon changing and title changing and DEMANDS_ATTENTION support
	FIXME: if a screen detaches because it is being attached somewhere else, we should note that somehow
*/

struct Session {
	// preserved in the file
	string title;
	string icon;
	string cwd;
	string[] screens;
	dchar escapeCharacter = 1;
	bool showingTaskbar = true;

	// the filename
	string sname;

	// not preserved in the file
	ChildTerminal[] children;
	int activeScreen;

	void saveToFile() {
		import std.stdio;
		import std.string;
		if(sname.length == 0) return;
		auto file = File(socketDirectoryName() ~ "/" ~ sname ~ ".session", "wt");
		file.writeln("title: ", title);
		file.writeln("icon: ", icon);
		file.writeln("cwd: ", cwd);
		file.writeln("escapeCharacter: ", cast(dchar) (escapeCharacter + 'a' - 1));
		file.writeln("showingTaskbar: ", showingTaskbar);
		file.writeln("screens: ", join(screens, " "));
	}

	void readFromFile() {
		import std.stdio;
		import std.string;
		import std.file;
		if(sname.length == 0) return;
		if(!std.file.exists(socketDirectoryName() ~ "/" ~ sname ~ ".session"))
			return;
		auto file = File(socketDirectoryName() ~ "/" ~ sname ~ ".session", "rt");
		foreach(line; file.byLine) {
			auto idx = indexOf(line, ":");
			if(idx == -1)
				continue;
			auto lhs = strip(line[0 .. idx]);
			auto rhs = strip(line[idx + 1 .. $]);
			switch(lhs) {
				case "title": title = rhs.idup; break;
				case "cwd": cwd = rhs.idup; break;
				case "icon": icon = rhs.idup; break;
				case "escapeCharacter":
					import std.utf;
					escapeCharacter = decodeFront(rhs) + 1 - 'a';
				break;
				case "showingTaskbar": showingTaskbar = rhs == "true"; break;
				case "screens": screens = split(rhs.idup, " "); break;
				default: continue;
			}
		}
	}
}

struct ChildTerminal {
	Socket socket;
	string title;

	string socketName;
	// tab image

	bool demandsAttention;

	// for mouse click detection
	int x;
	int x2;
}

extern(C) nothrow static @nogc
void detachable_child_dead(int) {
	import core.sys.posix.sys.wait;
	wait(null);
}

bool debugMode;
bool outputPaused;
int previousScreen = 0;
bool running = true;
Socket socket;

void main(string[] args) {

	Session session;

	if(args.length > 1) {
		import std.algorithm : endsWith;

		if(args.length == 2 && !endsWith(args[1], ".socket")) {
			// load the given argument as a session
			session.sname = args[1];
		} else {
			// make an anonymous session with the listed screens as sockets
			foreach(arg; args[1 .. $])
				session.screens ~= arg;
		}
	} else {
		// list the available sockets and sessions...
		import std.file, std.process, std.stdio;
		bool found = false;
		auto dirName = socketDirectoryName();
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

	session.cwd = std.file.getcwd();
	session.title = session.sname;
	session.readFromFile();

	if(session.cwd.length)
		std.file.chdir(session.cwd);

	bool good = false;

	foreach(idx, sname; session.screens) {
		if(sname == "[vacant]") {
			session.children ~= ChildTerminal(null, sname, sname);
			continue;
		}
		auto socket = connectTo(sname);
		if(socket is null)
			sname = "[failed]";
		else
			good = true;
		session.children ~= ChildTerminal(socket, sname, sname);

		// we should scan inactive sockets for:
		// 1) a bell
		// 2) a title change
		// 3) a window icon change

		// as these can all be reflected in the tab listing
	}

	if(session.children.length == 0)
		session.children ~= ChildTerminal(null, null, null);

	assert(session.children.length);

	if(!good) {
		if(session.children[0].socketName == "[vacant]" || session.children[0].socketName == "[failed]")
			session.children[0].socketName = null;
		session.children[0].socket = connectTo(session.children[0].socketName);
	}

	// doing these just to get it in the state i want
	auto terminal = Terminal(ConsoleOutputType.cellular);
	auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);

	// We got a bit beyond what Terminal does and also disable kernel flow
	// control, allowing us to capture ^S and ^Q too.
	// There's no need to reset at end of scope btw because RealTimeConsoleInput's dtor
	// resets to original state, saved before we make this change anyway.
	{
		import core.sys.posix.termios;
		// padding because I'm not sure druntime's termios is the correct size
		ubyte[128] padding;
		termios old;
		ubyte[128] padding2;
		tcgetattr(0 /* terminal.fdIn */, &old);
		old.c_iflag &= ~(IXON | IXOFF);
		tcsetattr(0, TCSANOW, &old);
	}

	// then all we do is forward data to/from stdin to the pipe
	import core.stdc.errno;
	import core.sys.posix.unistd;
	import core.sys.posix.sys.select;

	foreach(idx, child; session.children)
		if(child.socket !is null) {
			setActiveScreen(&terminal, session, idx, true);
			break;
		}
	if(socket is null)
		return;

	/*
	// sets the icon, if set
	if(session.icon.length) {
		import arsd.terminalextensions;
		changeWindowIcon(&terminal, session.icon);
	}
	*/

	while(running) {
		terminal.flush();
		ubyte[4096] buffer;
		fd_set rdfs;
		FD_ZERO(&rdfs);

		FD_SET(0, &rdfs);
		int maxFd = 0;
		foreach(child; session.children) {
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
					handleEvent(&terminal, session, input.nextEvent(), socket);
				continue; // EINTR
			}
			else throw new Exception("select");
		}

		if(ret) {
			bool redrawTaskbar = false;

			if(FD_ISSET(0, &rdfs)) {
				// the terminal is ready, we'll call next event here
				handleEvent(&terminal, session, input.nextEvent(), socket);
			}

			foreach(ref child; session.children) {
				if(child.socket !is null)
				if(FD_ISSET(child.socket.handle, &rdfs)) {
					// data from the pty should be forwarded straight out
					int len = read(child.socket.handle, buffer.ptr, buffer.length);
					if(len <= 0) {
						// probably end of file or something cuz the child exited
						// we should switch to the next possible screen
						// throw new Exception("closing cuz of bad read " ~ to!string(errno));
						closeSocket(&terminal, session, child.socket);

						continue;
					}

					/* read just for stuff in the background like bell or title change */
					int lastEsc = -1;
					int cut1 = 0, cut2 = 0;
					foreach(bidx, b; buffer[0 .. len]) {
						if(b == '\033')
							lastEsc = bidx;

						if(b == '\007') {
							if(lastEsc != -1) {
								auto pieces = cast(char[]) buffer[lastEsc .. bidx];
								cut1 = lastEsc;
								cut2 = 0;
								lastEsc = -1;

								// anything longer is just unreasonable
								if(pieces.length > 4 && pieces.length < 60)
								if(pieces[1] == ']' && pieces[2] == '0' && pieces[3] == ';') {
									child.title = pieces[4 .. $].idup;
									redrawTaskbar = true;

									cut2 = bidx;
								}
							}
							if(child.socket !is socket) {
								child.demandsAttention = true;
								redrawTaskbar = true;
							}
						}
					}

					// activity on the active screen needs to be forwarded
					// to the actual terminal so the user can see it too
					if(!outputPaused && child.socket is socket) {
						auto toWrite = buffer[0 .. len];
						void writeOut(ubyte[] toWrite) {
							auto len = toWrite.length;
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

						// FIXME
						if(false && cut2 > cut1) {
							// cut1 .. cut2 should be sliced out of the final output
							// a title change isn't necessarily desirable directly since
							// we do it in the session
							writeOut(buffer[0 .. cut1]);
							writeOut(buffer[cut2 + 1 .. $]);
						} else {
							writeOut(buffer[0 .. len]);
						}
					}
				}
			}

			if(redrawTaskbar)
				drawTaskbar(&terminal, session);
		}
	}

	if(session.sname !is null) {
		session.screens = null;
		foreach(child; session.children) {
			if(child.socket !is null)
				session.screens ~= child.socketName;
			else
				session.screens ~= "[vacant]";
		}
		session.saveToFile();
	}
}


Socket connectTo(ref string sname, in bool spawn = true) {
	Socket socket;

	if(sname.length) {
		try {
			socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
			socket.connect(new UnixAddress(socketFileName(sname)));
		} catch(Exception e) {
			socket = null;
		}
	}

	if(socket is null && spawn) {
		// if it can't connect, we'll spawn a new backend to control it
		import core.sys.posix.unistd;
		if(auto pid = fork()) {
			import std.conv;
			sname = to!string(pid);
			int tries = 3;
			while(tries > 0 && socket is null) {
				// give the child a chance to get started...
				import core.thread;
				Thread.sleep(dur!"msecs"(25));

				// and try to connect
				socket = connectTo(sname, false);
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
	return socket;
}


void drawTaskbar(Terminal* terminal, ref Session session) {
	static string lastTitleDrawn;
	bool anyDemandAttention = false;
	if(session.showingTaskbar) {
		terminal.writeStringRaw("\0337"); // save cursor
		scope(exit) {
			terminal.writeStringRaw("\0338"); // restore cursor
		}

		int spaceRemaining = terminal.width;
		terminal.moveTo(0, terminal.height - 1);
		//terminal.writeStringRaw("\033[K"); // clear line
		terminal.color(Color.DEFAULT, Color.DEFAULT, ForceOption.alwaysSend, true);
		terminal.write("+ ");
		spaceRemaining-=2;
		spaceRemaining--; // save space for the close button on the end

		foreach(idx, ref child; session.children) {
			child.x = terminal.width - spaceRemaining - 1;
			terminal.color(Color.DEFAULT, child.demandsAttention ? Color.green : Color.DEFAULT, ForceOption.automatic, idx != session.activeScreen);
			terminal.write(" ");
			spaceRemaining--;

			anyDemandAttention = anyDemandAttention || child.demandsAttention;

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

	if(anyDemandAttention) {
		 import std.process;
		 if(environment["TERM"] != "linux")
			terminal.writeStringRaw("\033]5001;1\007");
	}

	string titleToDraw;
	if(session.title.length)
		titleToDraw = session.title ~ " - " ~ session.children[session.activeScreen].title;
	else
		titleToDraw = session.children[session.activeScreen].title;

	// FIXME
	if(true || lastTitleDrawn != titleToDraw) {
		lastTitleDrawn = titleToDraw;
		terminal.setTitle(titleToDraw);
	}
}

int nextScreen(ref Session session) {
	foreach(i; session.activeScreen + 1 .. session.children.length)
		if(session.children[i].socket !is null)
			return i;
	foreach(i; 0 .. session.activeScreen)
		if(session.children[i].socket !is null)
			return i;
	return session.activeScreen;
}

int nextScreenBackwards(ref Session session) {
	foreach_reverse(i; 0 .. session.activeScreen)
		if(session.children[i].socket !is null)
			return i;
	foreach_reverse(i; session.activeScreen + 1 .. session.children.length)
		if(session.children[i].socket !is null)
			return i;
	return session.activeScreen;
}

void attach(Terminal* terminal, ref Session session, string sname) {
	int position = -1;
	foreach(idx, child; session.children)
		if(child.socket is null) {
			position = idx;
			break;
		}
	if(position == -1) {
		position = session.children.length;
		session.children ~= ChildTerminal();
	}

	// spin off the child process

	auto newSocket = connectTo(sname);
	if(newSocket) {
		session.children[position] = ChildTerminal(newSocket, sname, sname);
		setActiveScreen(terminal, session, position);
	}
}

void handleEvent(Terminal* terminal, ref Session session, InputEvent event, Socket socket) {
	// FIXME: UI stuff
	static bool escaping;
	static bool gettingCommandLine;
	static LineGetter lineGetter;
	
	InputMessage im;
	im.eventLength = im.sizeof;
	InputMessage* eventToSend;


	if(gettingCommandLine) {
		if(!lineGetter.workOnLine(event)) {
			gettingCommandLine = false;
			auto cmdLine = lineGetter.finishGettingLine();

			import std.string;
			auto args = split(cmdLine, " ");
			if(args.length)
			switch(args[0]) {
				case "attach":
					attach(terminal, session, args.length > 1 ? args[1] : null);
				break;
				default:
			}

			outputPaused = false;
			forceRedraw(terminal, session);
		}

		return;
	}

	void triggerCommandLine(string text = "") {
		terminal.moveTo(0, terminal.height - 1);
		terminal.color(Color.DEFAULT, Color.DEFAULT, ForceOption.alwaysSend, true);
		terminal.write(":");
		foreach(i; 1 .. terminal.width)
			terminal.write(" ");
		terminal.moveTo(1, terminal.height - 1);
		gettingCommandLine = true;
		if(lineGetter is null)
			lineGetter = new LineGetter(terminal);
		lineGetter.startGettingLine();
		lineGetter.addString(text);
		outputPaused = true;

		if(text.length)
			lineGetter.redraw();
	}

	final switch(event.type) {
		case InputEvent.Type.CharacterEvent:
			auto ce = event.get!(InputEvent.Type.CharacterEvent);
			if(ce.eventType == CharacterEvent.Type.Released)
				return;

			if(escaping) {
				// C-a C-a toggles active screens quickly
				if(session.escapeCharacter != dchar.init && ce.character == session.escapeCharacter) {
					if(previousScreen != session.activeScreen && previousScreen < session.children.length && session.children[previousScreen].socket !is null)
						setActiveScreen(terminal, session, previousScreen);
					else {
						setActiveScreen(terminal, session, nextScreen(session));
					}
					// C-a a sends C-a to the child.
				} else if(session.escapeCharacter != dchar.init && ce.character == session.escapeCharacter + 'a' - 1) {
					im.type = InputMessage.Type.CharacterPressed;
					im.characterEvent.character = 1;
					eventToSend = &im;
				} else switch(ce.character) {
					case 'q': debugMode = !debugMode; break;
					case 't':
						session.showingTaskbar = !session.showingTaskbar;
						forceRedraw(terminal, session); // redraw full because the height changes
					break;
					case ' ':
						setActiveScreen(terminal, session, nextScreen(session));
					break;
					case 'd':
						// detach the session
						running = false;
					break;
					case 'D':
						// detach only the screen
						closeSocket(terminal, session);
					break;
					case 12: // ^L
						forceRedraw(terminal, session);
					break;
					case '"':
						// list everything and give ui to choose
					break;
					case ':':
						triggerCommandLine();
					break;
					case 'c':
						attach(terminal, session, null);
					break;
					case 'C':
						triggerCommandLine("attach ");
					break;
					case '0':
					..
					case '9':
						int num = cast(int) (ce.character - '0');
						if(num == 0)
							num = 9;
						else
							num--;
						setActiveScreen(terminal, session, num);
					break;
					default:
				}
				escaping = false;
			} else if(ce.character == session.escapeCharacter) {
				escaping = true;
			} else {
				im.type = InputMessage.Type.CharacterPressed;
				im.characterEvent.character = ce.character;
				eventToSend = &im;
			}
		break;
		case InputEvent.Type.SizeChangedEvent:
			/*
			auto ce = event.get!(InputEvent.Type.SizeChangedEvent);
			im.type = InputMessage.Type.SizeChanged;
			im.sizeEvent.width = ce.newWidth;
			im.sizeEvent.height = ce.newHeight - (session.showingTaskbar ? 1 : 0);
			eventToSend = &im;
			*/
			forceRedraw(terminal, session);  // the forced redraw will send the new size too
		break;
		case InputEvent.Type.UserInterruptionEvent:
			im.type = InputMessage.Type.CharacterPressed;
			im.characterEvent.character = '\003';
			eventToSend = &im;
		break;
		case InputEvent.Type.NonCharacterKeyEvent:
			auto ev = event.get!(InputEvent.Type.NonCharacterKeyEvent);
			if(ev.eventType == NonCharacterKeyEvent.Type.Pressed) {

				if(escaping) {
					switch(ev.key) {
						case NonCharacterKeyEvent.Key.LeftArrow:
							setActiveScreen(terminal, session, nextScreenBackwards(session));
						break;
						case NonCharacterKeyEvent.Key.RightArrow:
							setActiveScreen(terminal, session, nextScreen(session));
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

			if(session.showingTaskbar && me.y == terminal.height - 1) {
				if(me.eventType == MouseEvent.Type.Pressed)
					foreach(idx, child; session.children) {
						if(me.x >= child.x && me.x < child.x2) {
							setActiveScreen(terminal, session, idx);
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
		import core.sys.posix.unistd;
		auto len = write(socket.handle, eventToSend, eventToSend.eventLength);
		if(len <= 0) {
			closeSocket(terminal, session);
		}
	}
}

void forceRedraw(Terminal* terminal, ref Session session) {
	assert(!outputPaused);
	setActiveScreen(terminal, session, session.activeScreen, true);
}

void setActiveScreen(Terminal* terminal, ref Session session, int s, bool force = false) {
	if(s < 0 || s >= session.children.length)
		return;
	if(session.activeScreen == s && !force)
		return; // already active
	if(session.children[s].socket is null)
		return; // vacant slot cannot be activated

	if(previousScreen != session.activeScreen)
		previousScreen = session.activeScreen;
	session.activeScreen = s;

	session.children[s].demandsAttention = false;

	terminal.clear();

	socket = session.children[s].socket;

	drawTaskbar(terminal, session);

	// force the size
	{
		InputMessage im;
		im.eventLength = im.sizeof;
		im.sizeEvent.width = terminal.width;
		im.sizeEvent.height = terminal.height - (session.showingTaskbar ? 1 : 0);
		im.type = InputMessage.Type.SizeChanged;
		import core.sys.posix.unistd;
		write(socket.handle, &im, im.eventLength);
	}

	// and force a redraw
	{
		InputMessage im;
		im.eventLength = im.sizeof;
		im.type = InputMessage.Type.RedrawNow;
		import core.sys.posix.unistd;
		write(socket.handle, &im, im.eventLength);
	}
}

void closeSocket(Terminal* terminal, ref Session session, Socket socketToClose = null) {
	if(socketToClose is null)
		socketToClose = socket;
	assert(socketToClose !is null);

	int switchTo = -1;
	foreach(idx, ref child; session.children) {
		if(child.socket is socketToClose) {
			if(idx == session.children.length - 1) {
				session.children = session.children[0 .. $-1];
				while(session.children.length && session.children[$-1].socket is null)
					session.children = session.children[0 .. $-1];
			} else {
				child.socket = null;
				child.title = "[vacant]";
			}
			switchTo = previousScreen;
			break;
		}
	}

	socketToClose.shutdown(SocketShutdown.BOTH);
	socketToClose.close();

	if(socketToClose !is socket) {
		drawTaskbar(terminal, session);
		return; // no need to close; it isn't the active socket
	}

	socket = null;

	if(switchTo >= session.children.length)
		switchTo = 0;

	foreach(s; switchTo .. session.children.length)
		if(session.children[s].socket !is null) {
			switchTo = s;
			goto allSet;
		}
	foreach(s; 0 .. switchTo)
		if(session.children[s].socket !is null) {
			switchTo = s;
			goto allSet;
		}

	switchTo = -1;

	allSet:

	if(switchTo < 0 || switchTo >= session.children.length) {
		running = false;
		socket = null;
		return;
	} else if(session.children[switchTo].socket is null) {
		running = false;
		socket = null;
		return;
	}
	setActiveScreen(terminal, session, switchTo, true);
}



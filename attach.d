// FIXME: catch the suspend signal (ctrl+z) and forward it inside
// FIXME: i should be able to change the title from the outside too
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

import arsd.terminal;

static import std.file;
static import core.stdc.stdlib;
import std.conv;
import std.socket;

/*
	FIXME: error messages aren't displayed when you attach and the socket cannot be opened

	FIXME: activity/silence watching should make sense out of the box so default on doesn't annoy me
	FIXME: when a session is remote attached, it steals all the screens. this causes the existing one
	       to write out a blank session file, meaning it won't be stolen back easily. This should change
	       so it is aware of the remote detach and just leaves things, or gracefully exits upon request.

	fun facts:
		SIGTSTP is the one we catch
		SIGCONT is the one to send to make it continue
	Session file example:

	title: foo
	icon: bar.png
	cwd: /home/me
	screens: foo bar baz

	FIXME: support icon changing and title changing and DEMANDS_ATTENTION support
	FIXME: if a screen detaches because it is being attached somewhere else, we should note that somehow

	FIXME: support the " key
	FIXME: watch for change in silence automatically
	FIXME: allow suppression of beeps


	so what do i want for activity noticing...
		if it has been receiving user input, give it a bigger time out

		if there's been no output for a minute, consider it silent
		if there has been output in the last minute, it is not silent

		if it is less than a minute old, it is neither silent nor loud yet
*/

struct Session {
	import core.sys.posix.sys.types;
	pid_t pid; // a hacky way to keep track of who has this open right now for remote detaching

	// preserved in the file
	string title;
	string icon;
	string cwd;
	string[] screens;
	string[] screensTitlePrefixes;
	string autoCommand;
	dchar escapeCharacter = 1;
	bool showingTaskbar = true;

	/// if set to true, screens are counted from zero when jumping with the number keys (like GNU screen)
	/// otherwise, screens count from one. I like one because it is more convenient with the left hand
	/// and the numbers match up visually with the tabs, but the zero based gnu screen habit is hard to break.
	bool zeroBasedCounting;

	// the filename
	string sname;

	bool mouseTrackingOn;

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
		file.writeln("autoCommand: ", autoCommand);
		file.writeln("escapeCharacter: ", cast(dchar) (escapeCharacter + 'a' - 1));
		file.writeln("showingTaskbar: ", showingTaskbar);
		file.writeln("zeroBasedCounting: ", zeroBasedCounting);
		file.writeln("pid: ", pid);
		file.writeln("activeScreen: ", activeScreen);
		file.writeln("screens: ", join(screens, " "));
		file.writeln("screensTitlePrefixes: ", join(screensTitlePrefixes, "; "));
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
				case "autoCommand": autoCommand = rhs.idup; break;
				case "icon": icon = rhs.idup; break;
				case "escapeCharacter":
					import std.utf;
					escapeCharacter = decodeFront(rhs) + 1 - 'a';
				break;
				case "showingTaskbar": showingTaskbar = rhs == "true"; break;
				case "zeroBasedCounting": zeroBasedCounting = rhs == "true"; break;
				case "pid": pid = to!int(rhs); break;
				case "activeScreen": activeScreen = to!int(rhs); break;
				case "screens": screens = split(rhs.idup, " "); break;
				case "screensTitlePrefixes": screensTitlePrefixes = split(line[idx + 1 .. $].stripLeft.idup, "; "); break;
				default: continue;
			}
		}
	}

	void saveUpdatedSessionToFile() {
		if(this.sname !is null) {
			this.screens = null;
			this.screensTitlePrefixes = null;
			foreach(child; this.children) {
				if(child.socket !is null) {
					this.screens ~= child.socketName;
				} else {
					this.screens ~= "[vacant]";
				}

				this.screensTitlePrefixes ~= child.titlePrefix;
			}
			this.saveToFile();
		}
	}
}

import core.stdc.time;

struct ChildTerminal {
	Socket socket;
	string title;

	string socketName;
	// tab image

	string titlePrefix;

	bool demandsAttention;

	// for mouse click detection
	int x;
	int x2;

	// for detecting changes in output
	time_t lastActivity;
	bool lastWasSilent;
}

extern(C) nothrow static @nogc
void detachable_child_dead(int) {
	import core.sys.posix.sys.wait;
	wait(null);
}

bool stopRequested;

extern(C) nothrow static @nogc
void stop_requested(int) {
	stopRequested = true;
}


bool debugMode;
bool outputPaused;
int previousScreen = 0;
bool running = true;
Socket socket;

void main(string[] args) {

	Session session;

	if(args.length > 1 && args[1] != "--list" && args[1] != "--cleanup") {
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

		string[] sessions;
		string[] sockets;

		foreach(string name; dirEntries(dirName, SpanMode.shallow)) {
			name = name[dirName.length + 1 .. $];
			if(name[$-1] == 'n')
				sessions ~= name[0 .. $ - ".session".length];
			else
				sockets ~= name[0 .. $ - ".socket".length];
			found = true;
		}
		if(found) {
			string[string] associations;
			foreach(sessionName; sessions) {
				auto sess = Session();
				sess.sname = sessionName;
				sess.readFromFile();

				foreach(s; sess.screens)
					associations[s] = sessionName;

				if(args.length == 2 && args[1] == "--cleanup") {

				} else
					writefln("%20s\t%d\t%d", sessionName, sess.pid, sess.screens.length);
			}

			foreach(socketName; sockets) {
				if(args.length == 2 && args[1] == "--cleanup") {
					if(socketName !in associations) {
						import core.stdc.stdlib;
						static import std.file;
						if(std.file.exists("/proc/" ~ socketName))
							system(("attach " ~ socketName ~ ".socket" ~ "\0").ptr);
						else
							std.file.remove(socketDirectoryName() ~ "/" ~ socketName ~ ".socket");
					}
				} else {
					writefln("%s.socket\t\t%s", socketName, (socketName in associations) ? associations[socketName] : "[detached]");

					static import std.file;
					if(std.file.exists("/proc/" ~ socketName)) {
						auto newSocket = connectTo(socketName, false);
						if(newSocket) {
							sendSimpleMessage(newSocket, InputMessage.Type.RequestStatus);
							char[1024] buffer;
							auto read = newSocket.receive(buffer[]);
							while(read > 0) {
								writef("%s", buffer[0 .. read]);
								read = newSocket.receive(buffer[]);
							}
							newSocket.close();
						}
					}
				}
			}
		} else {
			writeln("No screens found");
		}
		return;
	}

	import core.sys.posix.signal;
	signal(SIGPIPE, SIG_IGN);
	signal(SIGCHLD, &detachable_child_dead);
	signal(SIGTSTP, &stop_requested);

	import std.process;

	// FIXME: set up a FIFO or something so we can receive commands
	// pertaining to the whole session like detach... or something.
	// if we do that it will need a way to find it by session name
	// or by pid. Maybe a symlink.

	session.cwd = std.file.getcwd();
	session.title = session.sname;
	session.readFromFile();

	if(session.pid) {
		// detach the old session
		kill(session.pid, SIGHUP);
		import core.sys.posix.unistd;
		usleep(1_000_000); // give the old process a chance to die
		session.readFromFile();
	}

	session.pid = thisProcessID();

	if(session.cwd.length)
		std.file.chdir(session.cwd);

	bool good = false;

	foreach(idx, sname; session.screens) {
		if(sname == "[vacant]") {
			session.children ~= ChildTerminal(null, sname, sname, idx < session.screensTitlePrefixes.length ? session.screensTitlePrefixes[idx] : null);
			continue;
		}
		auto socket = connectTo(sname);
		if(socket is null)
			sname = "[failed]";
		else {
			good = true;
			sendSimpleMessage(socket, InputMessage.Type.Attach);
		}
		session.children ~= ChildTerminal(socket, sname, sname, idx < session.screensTitlePrefixes.length ? session.screensTitlePrefixes[idx] : null);

		// we should scan inactive sockets for:
		// 1) a bell
		// 2) a title change
		// 3) a window icon change

		// as these can all be reflected in the tab listing
	}

	if(session.children.length == 0)
		session.children ~= ChildTerminal(null, null, null, null);

	assert(session.children.length);

	if(!good) {
		if(session.children[0].socketName == "[vacant]" || session.children[0].socketName == "[failed]")
			session.children[0].socketName = null;
		session.children[0].socket = connectTo(session.children[0].socketName);
		if(auto socket = session.children[0].socket) {
			sendSimpleMessage(socket, InputMessage.Type.Attach);

			if(session.autoCommand.length)
				sendSimulatedInput(socket, session.autoCommand);
		}
	}


	session.saveUpdatedSessionToFile(); // saves the new PID

	// doing these just to get it in the state i want
	auto terminal = Terminal(ConsoleOutputType.cellular);
	auto input = RealTimeConsoleInput(&terminal, ConsoleInputFlags.raw | ConsoleInputFlags.allInputEvents);
	try {

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
		old.c_iflag &= ~(IXON | IXOFF | ISIG);
		old.c_cc[VQUIT] = 0; // disable the ctrl+\ signal so it can be handled on the inner layer too
		tcsetattr(0, TCSANOW, &old);
	}

	// then all we do is forward data to/from stdin to the pipe
	import core.stdc.errno;
	import core.sys.posix.unistd;
	import core.sys.posix.sys.select;

	if(session.activeScreen < session.children.length && session.children[session.activeScreen].socket !is null) {
		setActiveScreen(&terminal, session, cast(int) session.activeScreen, true);
	} else {
		foreach(idx, child; session.children)
			if(child.socket !is null) {
				setActiveScreen(&terminal, session, cast(int) idx, true);
				break;
			}
	}
	if(socket is null)
		return;

	// sets the icon, if set
	if(session.icon.length) {
		import arsd.terminalextensions;
		changeWindowIcon(&terminal, session.icon);
	}

	while(running) {
		if(stopRequested) {
			stopRequested = false;

			InputMessage im;
			im.type = InputMessage.Type.CharacterPressed;
			im.characterEvent.character = 26; // ctrl+z
			im.eventLength = im.sizeof;
			write(socket.handle, &im, im.eventLength);
		}

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

		timeval timeout;
		timeout.tv_sec = 10;

		auto ret = select(maxFd + 1, &rdfs, null, null, &timeout);
		if(ret == -1) {
			if(errno == 4) { // EAGAIN
				while(running && (interrupted || windowSizeChanged || hangedUp))
					handleEvent(&terminal, session, input.nextEvent(), socket);
				continue; // EINTR
			}
			else throw new Exception("select");
		}

		bool redrawTaskbar = false;

		if(ret) {

			if(FD_ISSET(0, &rdfs)) {
				// the terminal is ready, we'll call next event here
				while(running && input.anyInput_internal())
				handleEvent(&terminal, session, input.nextEvent(), socket);
			}

			foreach(ref child; session.children) if(child.socket !is null) {
				if(FD_ISSET(child.socket.handle, &rdfs)) {
					// data from the pty should be forwarded straight out
					auto len = read(child.socket.handle, buffer.ptr, cast(int) 2);
					if(len <= 0) {
						// probably end of file or something cuz the child exited
						// we should switch to the next possible screen
						//throw new Exception("closing cuz of bad read " ~ to!string(errno) ~ " " ~ to!string(len));
						closeSocket(&terminal, session, child.socket);

						continue;
					}

					assert(len == 2); // should be a frame
					// unpack the frame
					OutputMessageType messageType = cast(OutputMessageType) buffer[0];
					ubyte messageLength = buffer[1];
					if(messageLength) {
						// unpack the message
						int where = 0;
						while(where < messageLength) {
							len = read(child.socket.handle, buffer.ptr + where, messageLength - where);
							if(len <= 0) assert(0);
							where += len;
						}
						assert(where == messageLength);
					}


					void handleDataFromTerminal() {
						/* read just for stuff in the background like bell or title change */
						int lastEsc = -1;
						int cut1 = 0, cut2 = 0;
						foreach(bidx, b; buffer[0 .. messageLength]) {
							if(b == '\033')
								lastEsc = cast(int) bidx;

							if(b == '\007') {
								if(lastEsc != -1) {
									auto pieces = cast(char[]) buffer[lastEsc .. bidx];
									cut1 = lastEsc;
									cut2 = 0;
									lastEsc = -1;

									// anything longer is just unreasonable
									if(pieces.length > 4 && pieces.length < 120)
									if(pieces[1] == ']' && pieces[2] == '0' && pieces[3] == ';') {
										child.title = pieces[4 .. $].idup;
										redrawTaskbar = true;

										cut2 = cast(int) bidx;
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
							void writeOut(ubyte[] toWrite) {
								int len = cast(int) toWrite.length;
								while(len > 0) {
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
								writeOut(buffer[cut2 + 1 .. messageLength]);
							} else {
								writeOut(buffer[0 .. messageLength]);
							}
						}

						/+
						/* there's still new activity here */
						if(child.lastWasSilent && child.lastActivity) {
							child.demandsAttention = true;
							redrawTaskbar = true;
							child.lastWasSilent = false;
						}
						child.lastActivity = time(null);
						+/
					}

					final switch(messageType) {
						case OutputMessageType.NULL:
							// should never happen
							assert(0);
						//break;
						case OutputMessageType.dataFromTerminal:
							handleDataFromTerminal();
						break;
						case OutputMessageType.remoteDetached:
							// FIXME: this should be done on a session level

							// but the idea is if one is remote detached, they all are,
							// so we should just terminate immediately as to not write a new file
							return;
						//break;
						case OutputMessageType.mouseTrackingOn:
							session.mouseTrackingOn = true;
						break;
						case OutputMessageType.mouseTrackingOff:
							session.mouseTrackingOn = false;
						break;
					}
				} else {
					/+
					/* there was not any new activity, see if it has become silent */
					if(child.lastActivity && !child.lastWasSilent && time(null) - child.lastActivity > 10) {
						child.demandsAttention = true;
						child.lastWasSilent = true;
						redrawTaskbar = true;
					}
					+/
				}
			}
		} else {
			/+
			// it timed out, everybody is silent now
			foreach(ref child; session.children) {
				if(!child.lastWasSilent && child.lastActivity) {
					child.demandsAttention = true;
					child.lastWasSilent = true;
					redrawTaskbar = true;
				}
			}
			+/
		}

		if(redrawTaskbar)
			drawTaskbar(&terminal, session);
	}

	session.pid = 0; // we're terminating, don't keep the pid anymore
	session.saveUpdatedSessionToFile();
	 } catch(Throwable t) {
		terminal.writeln("\n\n\n", t);
		input.getch();
		input.getch();
		input.getch();
		input.getch();
		input.getch();
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
			if(sname.length == 0)
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
					auto toOverwrite = toOverwritePtr[0 .. strlen(toOverwritePtr) + 1];
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
		terminal.color(Color.blue, Color.white, ForceOption.alwaysSend, true);
		terminal.write("  "); //"+ ");
		spaceRemaining-=2;
		spaceRemaining--; // save space for the close button on the end

		foreach(idx, ref child; session.children) {
			child.x = terminal.width - spaceRemaining - 1;
			terminal.color(Color.blue, child.demandsAttention ? Color.green : Color.white, ForceOption.automatic, idx != session.activeScreen);
			terminal.write(" ");
			spaceRemaining--;

			anyDemandAttention = anyDemandAttention || child.demandsAttention;

			int size = 10;
			if(spaceRemaining < size)
				size = spaceRemaining;
			if(size <= 2)
				break;

			if(child.title.length == 0)
				child.title = "Screen " ~ to!string(idx + 1);

			auto dispTitle = child.titlePrefix.length ? (child.titlePrefix ~ child.title) : child.title;

			if(dispTitle.length <= size-2) {
				terminal.write(dispTitle);
				foreach(i; dispTitle.length .. size-2)
					terminal.write(" ");
			} else {
				terminal.write(dispTitle[0 .. size-2]);
			}
			terminal.write("  ");
			spaceRemaining -= size;
			child.x2 = terminal.width - spaceRemaining - 1;
			if(spaceRemaining == 0)
				break;
		}
		terminal.color(Color.blue, Color.white, ForceOption.automatic, true);

		foreach(i; 0 .. spaceRemaining)
			terminal.write(" ");
		terminal.write(" ");//"X");
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
			return cast(int) i;
	foreach(i; 0 .. session.activeScreen)
		if(session.children[i].socket !is null)
			return cast(int) i;
	return session.activeScreen;
}

int nextScreenBackwards(ref Session session) {
	foreach_reverse(i; 0 .. session.activeScreen)
		if(session.children[i].socket !is null)
			return cast(int) i;
	foreach_reverse(i; session.activeScreen + 1 .. session.children.length)
		if(session.children[i].socket !is null)
			return cast(int) i;
	return session.activeScreen;
}

void attach(Terminal* terminal, ref Session session, string sname) {
	int position = -1;
	foreach(idx, child; session.children)
		if(child.socket is null) {
			position = cast(int) idx;
			break;
		}
	if(position == -1) {
		position = cast(int) session.children.length;
		session.children ~= ChildTerminal();
	}

	// spin off the child process

	auto newSocket = connectTo(sname, true);
	if(newSocket) {
		sendSimpleMessage(newSocket, InputMessage.Type.Attach);

		session.children[position] = ChildTerminal(newSocket, sname, sname);
		setActiveScreen(terminal, session, position);

		if(session.autoCommand.length)
			sendSimulatedInput(newSocket, session.autoCommand);
	}
}

void sendSimpleMessage(Socket socket, InputMessage.Type type) {
	InputMessage im;
	im.eventLength = InputMessage.type.offsetof + InputMessage.type.sizeof;
	im.type = type;
	auto len = socket.send((cast(ubyte*)&im)[0 .. im.eventLength]);
	if(len <= 0) {
		throw new Exception("wtf");
	}
}

void handleEvent(Terminal* terminal, ref Session session, InputEvent event, Socket socket) {
	// FIXME: UI stuff
	static bool escaping;
	static bool gettingCommandLine;
	static bool gettingListSelection;
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
				case "title":
					session.children[session.activeScreen].titlePrefix = join(args[1..$], " ");
				break;
				default:
			}

			outputPaused = false;
			forceRedraw(terminal, session);
		}

		return;
	}

	if(gettingListSelection) {
		if(event.type == InputEvent.Type.CharacterEvent) {
			auto ce = event.get!(InputEvent.Type.CharacterEvent);
			if(ce.eventType == CharacterEvent.Type.Released)
				return;

			switch(ce.character) {
				case '0':
				..
				case '9':
					int num = cast(int) (ce.character - '0');
					if(!session.zeroBasedCounting) {
						if(num == 0)
							num = 9;
						else
							num--;
					}
					setActiveScreen(terminal, session, num);
				goto case;

				case '\n':
					gettingListSelection = false;
					outputPaused = false;
					forceRedraw(terminal, session);
					return;
				default:
			}
		}
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
		case InputEvent.Type.EndOfFileEvent:
			// assert(0);
			// FIXME: is this right too?
			running = false;
		break;
		case InputEvent.Type.HangupEvent:
			running = false;
		break;
		case InputEvent.Type.KeyboardEvent:
			break; // FIXME: KeyboardEvent replaces CharacterEvent and NonCharacterKeyEvent
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
					im.eventLength = im.characterEvent.offsetof + im.CharacterEvent.sizeof;
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
						// closeSocket(terminal, session); //  don't really like this
					break;
					case 'i':
						// request information
						terminal.writeln(session.children[session.activeScreen].socketName);
					break;
					case 12: // ^L
						forceRedraw(terminal, session);
					break;
					case '"':
						// list everything and give ui to choose
						// FIXME: finish the UI of this
						terminal.clear();
						foreach(idx, child; session.children)
							terminal.writeln("\t", idx + 1, ": ", child.titlePrefix, child.title, " (", child.socketName, ".socket)");
						gettingListSelection = true;
						outputPaused = true;
					break;
					case ':':
						triggerCommandLine();
					break;
					case 'c':
						attach(terminal, session, null);
						session.saveUpdatedSessionToFile();
					break;
					case 'C':
						triggerCommandLine("attach ");
					break;
					case '0':
					..
					case '9':
						int num = cast(int) (ce.character - '0');
						if(!session.zeroBasedCounting) {
							if(num == 0)
								num = 9;
							else
								num--;
						}
						setActiveScreen(terminal, session, num);
					break;
					default:
				}
				escaping = false;
			} else if(ce.character == session.escapeCharacter) {
				escaping = true;
			} else {
				im.type = InputMessage.Type.CharacterPressed;
				im.eventLength = im.characterEvent.offsetof + im.CharacterEvent.sizeof;
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
							if(ev.modifierState & ModifierState.alt) {
								// alt + arrow will move the tab
								if(session.activeScreen) {
									auto c = session.children[session.activeScreen - 1];
									session.children[session.activeScreen - 1] = session.children[session.activeScreen];
									session.children[session.activeScreen] = c;

									session.activeScreen--;
								}
								drawTaskbar(terminal, session);
							} else
								setActiveScreen(terminal, session, nextScreenBackwards(session));
						break;
						case NonCharacterKeyEvent.Key.RightArrow:
							if(ev.modifierState & ModifierState.alt) {
								// alt + arrow will move the tab
								if(session.activeScreen + 1 < session.children.length) {
									auto c = session.children[session.activeScreen + 1];
									session.children[session.activeScreen + 1] = session.children[session.activeScreen];
									session.children[session.activeScreen] = c;

									session.activeScreen++;
								}
								drawTaskbar(terminal, session);
							} else
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
				if((ev.modifierState & ModifierState.alt) || (ev.modifierState & ModifierState.meta))
					im.keyEvent.modifiers |= InputMessage.Alt;
				eventToSend = &im;
			}
		break;
		case InputEvent.Type.PasteEvent:
			auto ev = event.get!(InputEvent.Type.PasteEvent);
			auto data = new ubyte[](ev.pastedText.length + InputMessage.sizeof);
			auto msg = cast(InputMessage*) data.ptr;
			if(ev.pastedText.length > 4000)
				break; // FIXME
			msg.pasteEvent.pastedTextLength = cast(short) ev.pastedText.length;

			//terminal.writeln(ev.pastedText);

			// built-in array copy complained about byte overlap. Probably alignment or something.
			foreach(i, b; ev.pastedText)
				msg.pasteEvent.pastedText.ptr[i] = b;

			msg.type = InputMessage.Type.DataPasted;
			msg.eventLength = cast(short) data.length;
			eventToSend = msg;
		break;
		case InputEvent.Type.MouseEvent:
			auto me = event.get!(InputEvent.Type.MouseEvent);

			if(session.showingTaskbar && me.y == terminal.height - 1) {
				if(me.eventType == MouseEvent.Type.Pressed)
					foreach(idx, child; session.children) {
						if(me.x >= child.x && me.x < child.x2) {
							setActiveScreen(terminal, session, cast(int) idx);
							break;
						}
					}
				return;
			}

			final switch(me.eventType) {
				case MouseEvent.Type.Moved:
					im.type = InputMessage.Type.MouseMoved;
					if(!session.mouseTrackingOn && me.buttons == 0)
						return;
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

			im.mouseEvent.x = cast(short) me.x;
			im.mouseEvent.y = cast(short) me.y;
			im.mouseEvent.button = cast(ubyte) me.buttons;
			im.mouseEvent.modifiers = 0;
			if(me.modifierState & ModifierState.shift)
				im.mouseEvent.modifiers |= InputMessage.Shift;
			if(me.modifierState & ModifierState.control)
				im.mouseEvent.modifiers |= InputMessage.Ctrl;
			if(me.modifierState & ModifierState.alt || me.modifierState & ModifierState.meta)
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

void sendSimulatedInput(Socket socket, string input) {
	if(input.length == 0) return;
	if(socket is null) return;

	auto data = new ubyte[](input.length + InputMessage.sizeof);
	auto msg = cast(InputMessage*) data.ptr;

	msg.pasteEvent.pastedTextLength = cast(short) input.length;

	// built-in array copy complained about byte overlap. Probably alignment or something.
	foreach(i, b; input)
		msg.pasteEvent.pastedText.ptr[i] = b;

	msg.type = InputMessage.Type.DataPasted;
	msg.eventLength = cast(short) data.length;


	import core.sys.posix.unistd;
	auto len = write(socket.handle, msg, msg.eventLength);
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
		im.sizeEvent.width = cast(short) terminal.width;
		im.sizeEvent.height = cast(short) (terminal.height - (session.showingTaskbar ? 1 : 0));
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
			switchTo = cast(int) s;
			goto allSet;
		}
	foreach(s; 0 .. switchTo)
		if(session.children[s].socket !is null) {
			switchTo = cast(int) s;
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



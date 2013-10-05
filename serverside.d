/*
	This program is needed because the Windows version doesn't actually speak ssh.

	So it takes some special commands in lieu of the correct ssh packets for stuff like
	size ioctl calls.
*/

version(Posix) {
	extern(C) {
		pragma(lib, "util");
		int forkpty(int* master, /*int* slave,*/ void* name, void* termp, void* winp);
		int execl(const(char)* path, const(char*) arg, ...);
		int write(int fd, in void* buf, int count);
		int read(int fd, void* buf, int count);
		void wait(int);
		int ishit(int a);

		alias void function(int) sighandler_t;
		sighandler_t signal(int signum, sighandler_t handler);
		version(linux)
		enum int SIGCHLD = 17;
	}
	import core.sys.posix.termios;
	import core.stdc.errno;

	__gshared int childrenAlive = 0;
	extern(C)
	void childdead(int) {
		childrenAlive--;
	}

	import core.sys.posix.sys.select;
}


void main(string[] args) {
	int master;

	signal(SIGCHLD, &childdead);

	childrenAlive = 1;
	int pid = forkpty(&master, null, null, null);
	if(pid == -1)
		throw new Exception("forkpty");
	if(pid == 0) {
		import std.process;
		environment["TERM"] = "xterm"; // we're closest to an xterm, so definitely want to pretend to be one to the child processes
		environment["TERM_EXTENSIONS"] = "arsd";

		execl("/bin/bash", "/bin/bash", null);
	} else {
		ubyte[4096] buffer;
		while(childrenAlive) {
			fd_set rdfs;
			FD_ZERO(&rdfs);

			FD_SET(0, &rdfs);
			FD_SET(master, &rdfs);

			auto ret = select(master + 1, &rdfs, null, null, null);
			if(ret == -1) {
				if(errno == 4)
					continue; // EINTR
				else throw new Exception("select");
			}

			if(ret) {
				if(FD_ISSET(0, &rdfs)) {
					// data from ssh should be checked for magic, otherwise just forwarded
					int len = read(0, buffer.ptr, buffer.length);
					if(len <= 0)
						break; // perhaps they disconnected

					foreach(idx, b; buffer[0 .. len]) {
						if(b == 254 && idx + 2 < len) {
							// special command, resize

							winsize win;
							win.ws_col = buffer[idx + 1];
							win.ws_row = buffer[idx + 2];

							import core.sys.posix.sys.ioctl;
							ioctl(master, TIOCSWINSZ, &win);

							// cut it right out...
							foreach(i; 0 .. 3) {
								foreach(lol; idx .. len - 1)
									buffer[lol] = buffer[lol + 1];
								len--;
							}

							break;
						}
					}

					if(len)
						write(master, buffer.ptr, len);
				}

				if(FD_ISSET(master, &rdfs)) {
					// data from the pty should be forwarded straight out
					int len = read(master, buffer.ptr, buffer.length);
					if(len <= 0)
						break; // probably end of file or something cuz the child exited

					if(len)
						write(1, buffer.ptr, len);
				}
			}
		}
	}
}

/*
	This file sends various command sequences that terminalemulator.d understands.

	It should be usable as both a library for your applications and from the command line.

	./terminal-emulator-utility changeDefaultCursor bar
	                            ^^^^^^^^^^^^^^^^^^^ ^^^
				    function name       arguments

	Compile with -version=terminalextensions_commandline to produce the standalone binary.

	Perhaps terminal.d can use this too with ufcs.
*/

module arsd.terminalextensions;

import arsd.terminal; // for sending the commands
import arsd.terminalemulator; // for the various enums and small image encoding functions
import ac = arsd.color;

export void changeWindowIcon(Terminal* t, string filename) {
	import arsd.png;
	auto image = readPng(filename);
	auto ii = cast(IndexedImage) image;
	assert(ii !is null);

	/*
	foreach(idx, b; ii.data) {
		auto c = ii.palette[b];
		changeBackgroundColor(t, c);
		t.write(" ");

		if(idx % 16 == 0) {
			t.color(terminal.Color.DEFAULT, terminal.Color.DEFAULT, ForceOption.alwaysSend);
			t.writeln();
		}
	}*/

	t.writeStringRaw("\033]5000;"~encodeSmallTextImage(ii)~"\007");
}

export void changeForegroundColor(Terminal* t, ac.Color c) {
	import std.string;
	t.writeStringRaw(format("\033[38;2;%d;%d;%dm", c.r, c.g, c.b));
}

export void changeBackgroundColor(Terminal* t, ac.Color c) {
	import std.string;
	t.writeStringRaw(format("\033[48;2;%d;%d;%dm", c.r, c.g, c.b));
}

export void changeDefaultCursor(Terminal* t, TerminalEmulator.CursorStyle style) {
	t.writeStringRaw("");
}

export void changeCurrentCursor(Terminal* t, TerminalEmulator.CursorStyle style) {
	// default is [0 q
	final switch(style) {
		case TerminalEmulator.CursorStyle.block:
			t.writeStringRaw("\033[2 q");
		break;
		case TerminalEmulator.CursorStyle.underline:
			t.writeStringRaw("\033[4 q");
		break;
		case TerminalEmulator.CursorStyle.bar:
			t.writeStringRaw("\033[6 q");
		break;
	}
}

export void displayImage(Terminal* t, string filename) {
	t.writeStringRaw("\000");
	t.writeStringRaw(extensionMagicIdentifier);
	import std.base64, std.file;
	t.writeStringRaw(Base64.encode(cast(ubyte[]) std.file.read(filename)));
	t.writeStringRaw("\000");
}

// intended for things like attaching screen
export void clearScrollbackHistory(Terminal* t) {

}

void addScrollbackHistory(Terminal* t, string[] history) {

}

version(terminalextensions_commandline) {
	template PT(alias a) { alias PT = a; }
	void main(string[] args) {
		/*
		if(env["TERM_EXTENSIONS"] != "arsd")
			writeln("Warning: extensions may not be available on this terminal");
		*/

		auto term = Terminal(ConsoleOutputType.linear);
		term._suppressDestruction = true;

		string[] functions;

		alias mod = PT!(mixin("arsd.terminalextensions"));
		foreach(member; __traits(allMembers, mod))
		static if(__traits(compiles, PT!(__traits(getMember, mod, member)))) {
			alias mem = PT!(__traits(getMember, mod, member));
			static if(__traits(getProtection, mem) == "export") {
				if(args.length > 1 && member == args[1]) {
					// call it
					import std.traits;
					import std.conv;
					ParameterTypeTuple!mem a;
					a[0] = &term;

					foreach(i, arg; a) {
						static if(i) {
							static if(is(typeof(arg) == ac.Color))
								a[i] = ac.Color.fromString(args[i + 1]);
							else
								a[i] = to!(typeof(a[i]))(args[i + 1]);
						}
					}

					mem(a);
					return;
				}

				functions ~= member;
			}
		}

		term.writeln("Command not found, valid functions are:");
		foreach(func; functions)
			term.writeln("\t", func);


		term.flush();
	}
}

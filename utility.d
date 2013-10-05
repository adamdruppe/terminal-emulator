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

import terminal; // for sending the commands
import arsd.terminalemulator; // for the various enums (seems silly to pull the whole module just for some magic numbers though :( )

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

version(terminalextensions_commandline) {
	template PT(alias a) { alias PT = a; }
void main(string[] args) {
	auto term = Terminal(ConsoleOutputType.linear);

	alias mod = PT!(mixin("arsd.terminalextensions"));
	foreach(member; __traits(allMembers, mod)) {
		alias mem = PT!(__traits(getMember, mod, member));
		static if(__traits(getProtection, mem) == "export") {
			if(member == args[1]) {
				// call it
				import std.traits;
				import std.conv;
				ParameterTypeTuple!mem a;
				a[0] = &term;

				foreach(i, arg; a) {
					static if(i) {
						a[i] = to!(typeof(a[i]))(args[i + 1]);
					}
				}

				mem(a);
			}
		}
	}
}
}

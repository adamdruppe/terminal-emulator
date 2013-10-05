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

export void changeDefaultCursor(Terminal t, TerminalEmulator.CursorStyle style) {
	t.writeStringRaw("");
}

export void changeCurrentCursor(Terminal t) {
	t.writeStringRaw("");
}

version(terminalextensions_commandline) {
	template PT(alias a) { alias PT = a; }
void main(string[] args) {
	alias mod = PT!(mixin("arsd.terminalextensions"));
	foreach(member; __traits(allMembers, mod)) {
		alias mem = PT!(__traits(getMember, mod, member));
		static if(__traits(getProtection, mem) == "export") {
			import std.stdio;
			writeln(member);
		}
	}
}
}

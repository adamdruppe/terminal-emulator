/**
	FIXME: writing a line in color then a line in ordinary does something
	wrong.

	FIXME: make shift+enter send something special to the application
		and shift+space, etc.
		identify itself somehow too for client extensions


	There should be a redraw thing that is given batches of instructions
	in here that the other thing just implements.

	FIXME: the save stack stuff should do cursor style too

	This is an extendible unix terminal emulator and some helper functions to help actually implement one.

	You'll have to subclass TerminalEmulator and implement the abstract functions as well as write a drawing function for it.

	See nestedterminalemulator.d or main.d for how I did it.
*/
module arsd.terminalemulator;

import arsd.color;
import std.algorithm : max;

enum extensionMagicIdentifier = "ARSD Terminal Emulator binary extension data follows:";

interface NonCharacterData {
	//const(ubyte)[] serialize();
}

struct BrokenUpImage {
	int width;
	int height;
	TerminalEmulator.TerminalCell[] representation;
}

struct CustomGlyph {
	TrueColorImage image;
	dchar substitute;
}

void unknownEscapeSequence(in char[] esc) {
	import std.file;
	version(Posix)
	debug append("/tmp/arsd-te-bad-esc-sequences.txt", esc ~ "\n");
}

// This is used for the double-click word selection
bool isWordSeparator(dchar ch) {
	return ch == ' ' || ch == '"' || ch == '<' || ch == '>' || ch == '(' || ch == ')' || ch == ',';
}

struct ScopeBuffer(T, size_t maxSize) {
	T[maxSize] buffer;
	size_t length;
	bool isNull = true;
	T[] opSlice() { return isNull ? null : buffer[0 .. length]; }
	void opOpAssign(string op : "~")(in T rhs) {
		isNull = false;
		if(this.length < buffer.length) // i am silently discarding more crap
			buffer[this.length++] = rhs;
	}
	void opOpAssign(string op : "~")(in T[] rhs) {
		isNull = false;
		buffer[this.length .. this.length + rhs.length] = rhs[];
		this.length += rhs.length;
	}
	void opAssign(in T[] rhs) {
		isNull = rhs is null;
		buffer[0 .. rhs.length] = rhs[];
		this.length = rhs.length;
	}
	void opAssign(typeof(null)) {
		isNull = true;
		length = 0;
	}
	T opIndex(size_t idx) {
		assert(!isNull);
		assert(idx < length);
		return buffer[idx];
	}
	void clear() {
		isNull = true;
		length = 0; 
	}
}

/**
	An abstract class that does terminal emulation. You'll have to subclass it to make it work.

	The terminal implements a subset of what xterm does and then, optionally, some special features.

	Its linear mode (normal) screen buffer is infinitely long and infinitely wide. It is the responsibility
	of your subclass to do line wrapping, etc., for display. This i think is actually incompatible with xterm but meh.

	actually maybe it *should* automatically wrap them. idk. I think GNU screen does both. FIXME decide.

	Its cellular mode (alternate) screen buffer can be any size you want.
*/
class TerminalEmulator {
	/* override these to do stuff on the interface.
	You might be able to stub them out if there's no state maintained on the target, since TerminalEmulator maintains its own internal state */
	protected abstract void changeWindowTitle(string); /// the title of the window
	protected abstract void changeIconTitle(string); /// the shorter window/iconified window

	protected abstract void changeWindowIcon(IndexedImage); /// change the window icon. note this may be null

	protected abstract void changeCursorStyle(CursorStyle); /// cursor style

	protected abstract void changeTextAttributes(TextAttributes); /// current text output attributes
	protected abstract void soundBell(); /// sounds the bell
	protected abstract void sendToApplication(scope const(void)[]); /// send some data to the program running in the terminal, so keypresses etc.

	protected abstract void copyToClipboard(string); /// copy the given data to the clipboard (or you can do nothing if you can't)
	protected abstract void pasteFromClipboard(void delegate(in char[])); /// requests a paste. we pass it a delegate that should accept the data

	protected abstract void copyToPrimary(string); /// copy the given data to the PRIMARY X selection (or you can do nothing if you can't)
	protected abstract void pasteFromPrimary(void delegate(in char[])); /// requests a paste from PRIMARY. we pass it a delegate that should accept the data

	/// Signal the UI that some attention should be given, e.g. blink the taskbar or sound the bell.
	/// The default is to ignore the demand by instantly acknowledging it - if you override this, do NOT call super().
	protected void demandAttention() {
		attentionReceived();
	}

	/// After it demands attention, call this when the attention has been received
	/// you may call it immediately to ignore the demand (the default)
	public void attentionReceived() {
		attentionDemanded = false;
	}

	// I believe \033[50buffer[] and up are available for extensions everywhere.
	// when keys are shifted, xterm sends them as \033[1;2F for example with end. but is this even sane? how would we do it with say, F5?
	// apparently shifted F5 is ^[[15;2~
	// alt + f5 is ^[[15;3~
	// alt+shift+f5 is ^[[15;4~

	private string pasteDataPending = null;

	protected void justRead() {
		if(pasteDataPending.length) {
			sendPasteData(pasteDataPending);
			import core.thread; Thread.sleep(50.msecs); // hack to keep it from closing, broken pipe i think
		}
	}

	public void sendPasteData(scope const(char)[] data) {
		//if(pasteDataPending.length)
			//throw new Exception("paste data being discarded, wtf, shouldnt happen");

		if(bracketedPasteMode)
			sendToApplication("\033[200~");

		enum MAX_PASTE_CHUNK = 4000;
		if(data.length > MAX_PASTE_CHUNK) {
			// need to chunk it in order to receive echos, etc,
			// to avoid deadlocks
			pasteDataPending = data[MAX_PASTE_CHUNK .. $].idup;
			data = data[0 .. MAX_PASTE_CHUNK];
		} else {
			pasteDataPending = null;
		}

		if(data.length)
			sendToApplication(data);

		if(bracketedPasteMode)
			sendToApplication("\033[201~");
	}

	public string getSelectedText() {
		return getPlainText(selectionStart, selectionEnd);
	}

	bool dragging;
	int lastDragX, lastDragY;
	public bool sendMouseInputToApplication(int termX, int termY, MouseEventType type, MouseButton button, bool shift, bool ctrl, bool alt) {
		if(termX < 0)
			termX = 0;
		if(termX >= screenWidth)
			termX = screenWidth - 1;
		if(termY < 0)
			termY = 0;
		if(termY >= screenHeight)
			termY = screenHeight - 1;

		version(Windows) {
			// I'm swapping these because my laptop doesn't have a middle button,
			// and putty swaps them too by default so whatevs.
			if(button == MouseButton.right)
				button = MouseButton.middle;
			else if(button == MouseButton.middle)
				button = MouseButton.right;
		}

		int baseEventCode() {
			int b;
			// lol the xterm mouse thing sucks like javascript! unbelievable
			// it doesn't support two buttons at once...
			if(button == MouseButton.left)
				b = 0;
			else if(button == MouseButton.right)
				b = 2;
			else if(button == MouseButton.middle)
				b = 1;
			else if(button == MouseButton.wheelUp)
				b = 64 | 0;
			else if(button == MouseButton.wheelDown)
				b = 64 | 1;
			else
				b = 3; // none pressed or button released

			if(shift)
				b |= 4;
			if(ctrl)
				b |= 16;
			if(alt) // sending alt as meta
				b |= 8;

			return b;
		}


		if(type == MouseEventType.buttonReleased) {
			// X sends press and release on wheel events, but we certainly don't care about those
			if(button == MouseButton.wheelUp || button == MouseButton.wheelDown)
				return false;

			if(dragging) {
				auto text = getSelectedText();
				if(text.length) {
					copyToPrimary(text);
				}
			}

			dragging = false;
			if(mouseButtonReleaseTracking) {
				int b = baseEventCode;
				b |= 3; // always send none / button released
				ScopeBuffer!(char, 16) buffer;
				buffer ~= "\033[M";
				buffer ~= cast(char) (b | 32);
				buffer ~= cast(char) (termX+1 + 32);
				buffer ~= cast(char) (termY+1 + 32);
				sendToApplication(buffer[]);
			}
		}

		if(type == MouseEventType.motion) {
			if(termX != lastDragX || termY != lastDragY) {
				lastDragY = termY;
				lastDragX = termX;
				if(mouseMotionTracking || (mouseButtonMotionTracking && button)) {
					int b = baseEventCode;
					ScopeBuffer!(char, 16) buffer;
					buffer ~= "\033[M";
					buffer ~= cast(char) ((b | 32) + 32);
					buffer ~= cast(char) (termX+1 + 32);
					buffer ~= cast(char) (termY+1 + 32);
					sendToApplication(buffer[]);
				}

				if(dragging) {
					auto idx = termY * screenWidth + termX;

					// the no-longer-selected portion needs to be invalidated
					int start, end;
					if(idx > selectionEnd) {
						start = selectionEnd;
						end = idx;
					} else {
						start = idx;
						end = selectionEnd;
					}
					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[start .. end]) {
						cell.invalidated = true;
						cell.selected = false;
					}

					selectionEnd = idx;

					// and the freshly selected portion needs to be invalidated
					if(selectionStart > selectionEnd) {
						start = selectionEnd;
						end = selectionStart;
					} else {
						start = selectionStart;
						end = selectionEnd;
					}
					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[start .. end]) {
						cell.invalidated = true;
						cell.selected = true;
					}

					return true;
				}
			}
		}

		if(type == MouseEventType.buttonPressed) {
			// double click detection
			import std.datetime;
			static SysTime lastClickTime;
			static int consecutiveClicks = 1;

			if(button != MouseButton.wheelUp && button != MouseButton.wheelDown) {
				if(Clock.currTime() - lastClickTime < dur!"msecs"(350))
					consecutiveClicks++;
				else
					consecutiveClicks = 1;

				lastClickTime = Clock.currTime();
			}
			// end dbl click

			if(!(shift) && mouseButtonTracking) {
				int b = baseEventCode;

				int x = termX;
				int y = termY;
				x++; y++; // applications expect it to be one-based

				ScopeBuffer!(char, 16) buffer;
				buffer ~= "\033[M";
				buffer ~= cast(char) (b | 32);
				buffer ~= cast(char) (x + 32);
				buffer ~= cast(char) (y + 32);

				sendToApplication(buffer[]);
			} else {
				if(button == MouseButton.middle) {
					pasteFromPrimary(&sendPasteData);
				}

				if(button == MouseButton.wheelUp) {
					scrollback(alt ? 0 : (ctrl ? 10 : 1), alt ? -(ctrl ? 10 : 1) : 0);
					return true;
				}
				if(button == MouseButton.wheelDown) {
					scrollback(alt ? 0 : -(ctrl ? 10 : 1), alt ? (ctrl ? 10 : 1) : 0);
					return true;
				}

				if(button == MouseButton.left) {
					// we invalidate the old selection since it should no longer be highlighted...
					makeSelectionOffsetsSane(selectionStart, selectionEnd);

					auto activeScreen = (alternateScreenActive ? &alternateScreen : &normalScreen);
					foreach(ref cell; (*activeScreen)[selectionStart .. selectionEnd]) {
						cell.invalidated = true;
						cell.selected = false;
					}

					if(consecutiveClicks == 1) {
						selectionStart = termY * screenWidth + termX;
						selectionEnd = selectionStart;
					} else if(consecutiveClicks == 2) {
						selectionStart = termY * screenWidth + termX;
						selectionEnd = selectionStart;
						while(selectionStart > 0 && !isWordSeparator((*activeScreen)[selectionStart-1].ch)) {
							selectionStart--;
						}

						while(selectionEnd < (*activeScreen).length && !isWordSeparator((*activeScreen)[selectionEnd].ch)) {
							selectionEnd++;
						}

					} else if(consecutiveClicks == 3) {
						selectionStart = termY * screenWidth;
						selectionEnd = selectionStart + screenWidth;
					}
					dragging = true;
					lastDragX = termX;
					lastDragY = termY;

					// then invalidate the new selection as well since it should be highlighted
					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[selectionStart .. selectionEnd]) {
						cell.invalidated = true;
						cell.selected = true;
					}

					return true;
				}
				if(button == MouseButton.right) {
					auto oldSelectionEnd = selectionEnd;
					selectionEnd = termY * screenWidth + termX;

					if(selectionEnd < oldSelectionEnd) {
						auto tmp = selectionEnd;
						selectionEnd = oldSelectionEnd;
						oldSelectionEnd = tmp;
					}

					foreach(ref cell; (alternateScreenActive ? alternateScreen : normalScreen)[oldSelectionEnd .. selectionEnd]) {
						cell.invalidated = true;
						cell.selected = true;
					}

					auto text = getPlainText(selectionStart, selectionEnd);
					if(text.length) {
						copyToPrimary(text);
					}
					return true;
				}
			}
		}

		return false;
	}

	protected void returnToNormalScreen() {
		alternateScreenActive = false;

		if(cueScrollback) {
			showScrollbackOnScreen(normalScreen, 0, true, 0);
			newLine(false);
			cueScrollback = false;
		}
	}

	protected void outputOccurred() { }

	private int selectionStart; // an offset into the screen buffer
	private int selectionEnd; // ditto

	/// Send a non-character key sequence
	public bool sendKeyToApplication(TerminalKey key, bool shift = false, bool alt = false, bool ctrl = false, bool windows = false) {
		bool redrawRequired = false;

		// scrollback controls. Unlike xterm, I only want to do this on the normal screen, since alt screen
		// doesn't have scrollback anyway. Thus the key will be forwarded to the application.
		if((!alternateScreenActive || scrollingBack) && key == TerminalKey.PageUp && shift) {
			scrollback(10);
			return true;
		} else if((!alternateScreenActive || scrollingBack) && key == TerminalKey.PageDown && shift) {
			scrollback(-10);
			return true;
		} else if((!alternateScreenActive || scrollingBack)) { // && ev.key != Key.Shift && ev.key != Key.Shift_r) {
			if(endScrollback())
				redrawRequired = true;
		}



		void sendToApplicationModified(string s) {
			bool anyModifier = shift || alt || ctrl || windows;
			if(!anyModifier || applicationCursorKeys)
				sendToApplication(s); // FIXME: applicationCursorKeys can still be shifted i think but meh
			else {
				ScopeBuffer!(char, 16) modifierNumber;
				char otherModifier = 0;
				if(shift && alt && ctrl) modifierNumber = "8";
				if(alt && ctrl && !shift) modifierNumber = "7";
				if(shift && ctrl && !alt) modifierNumber = "6";
				if(ctrl && !shift && !alt) modifierNumber = "5";
				if(shift && alt && !ctrl) modifierNumber = "4";
				if(alt && !shift && !ctrl) modifierNumber = "3";
				if(shift && !alt && !ctrl) modifierNumber = "2";
				// FIXME: meta and windows
				// windows is an extension
				if(windows) {
					if(modifierNumber.length)
						otherModifier = '2';
					else
						modifierNumber = "20";
					/* // the below is what we're really doing
					int mn = 0;
					if(modifierNumber.length)
						mn = modifierNumber[0] + '0';
					mn += 20;
					*/
				}

				string keyNumber;
				char terminator;

				if(s[$-1] == '~') {
					keyNumber = s[2 .. $-1];
					terminator = '~';
				} else {
					keyNumber = "1";
					terminator = s[$ - 1];
				}

				ScopeBuffer!(char, 32) buffer;
				buffer ~= "\033[";
				buffer ~= keyNumber;
				buffer ~= ";";
				if(otherModifier)
					buffer ~= otherModifier;
				buffer ~= modifierNumber[];
				buffer ~= terminator;
				// the xterm style is last bit tell us what it is
				sendToApplication(buffer[]);
			}
		}

		alias TerminalKey Key;
		import std.stdio;
		// writefln("Key: %x", cast(int) key);
		final switch(key) {
			case Key.Left: sendToApplicationModified(applicationCursorKeys ? "\033OD" : "\033[D"); break;
			case Key.Up: sendToApplicationModified(applicationCursorKeys ? "\033OA" : "\033[A"); break;
			case Key.Down: sendToApplicationModified(applicationCursorKeys ? "\033OB" : "\033[B"); break;
			case Key.Right: sendToApplicationModified(applicationCursorKeys ? "\033OC" : "\033[C"); break;

			case Key.Home: sendToApplicationModified(applicationCursorKeys ? "\033OH" : (1 ? "\033[H" : "\033[1~")); break;
			case Key.Insert: sendToApplicationModified("\033[2~"); break;
			case Key.Delete: sendToApplicationModified("\033[3~"); break;

			// the 1? is xterm vs gnu screen. but i really want xterm compatibility.
			case Key.End: sendToApplicationModified(applicationCursorKeys ? "\033OF" : (1 ? "\033[F" : "\033[4~")); break;
			case Key.PageUp: sendToApplicationModified("\033[5~"); break;
			case Key.PageDown: sendToApplicationModified("\033[6~"); break;

			// the first one here is preferred, the second option is what xterm does if you turn on the "old function keys" option, which most apps don't actually expect
			case Key.F1: sendToApplicationModified(1 ? "\033OP" : "\033[11~"); break;
			case Key.F2: sendToApplicationModified(1 ? "\033OQ" : "\033[12~"); break;
			case Key.F3: sendToApplicationModified(1 ? "\033OR" : "\033[13~"); break;
			case Key.F4: sendToApplicationModified(1 ? "\033OS" : "\033[14~"); break;
			case Key.F5: sendToApplicationModified("\033[15~"); break;
			case Key.F6: sendToApplicationModified("\033[17~"); break;
			case Key.F7: sendToApplicationModified("\033[18~"); break;
			case Key.F8: sendToApplicationModified("\033[19~"); break;
			case Key.F9: sendToApplicationModified("\033[20~"); break;
			case Key.F10: sendToApplicationModified("\033[21~"); break;
			case Key.F11: sendToApplicationModified("\033[23~"); break;
			case Key.F12: sendToApplicationModified("\033[24~"); break;

			case Key.Escape: sendToApplicationModified("\033"); break;

			// see terminal.d for the other side of this
			case cast(TerminalKey) '\n': sendToApplicationModified("\033[83~"); break;
			case cast(TerminalKey) '\b': sendToApplicationModified("\033[78~"); break;
			case cast(TerminalKey) '\t': sendToApplicationModified("\033[79~"); break;
		}

		return redrawRequired;
	}

	/// if a binary extension is triggered, the implementing class is responsible for figuring out how it should be made to fit into the screen buffer
	protected /*abstract*/ BrokenUpImage handleBinaryExtensionData(const(ubyte)[]) {
		return BrokenUpImage();
	}

	/// If you subclass this and return true, you can scroll on command without needing to redraw the entire screen;
	/// returning true here suppresses the automatic invalidation of scrolled lines (except the new one).
	protected bool scrollLines(int howMany, bool scrollUp) {
		return false;
	}

	// might be worth doing the redraw magic in here too.
	// FIXME: not implemented
	@disable protected void drawTextSection(int x, int y, TextAttributes attributes, in dchar[] text, bool isAllSpaces) {
		// if you implement this it will always give you a continuous block on a single line. note that text may be a bunch of spaces, in that case you can just draw the bg color to clear the area
		// or you can redraw based on the invalidated flag on the buffer
	}
	// FIXME: what about image sections? maybe it is still necessary to loop through them

	/// Style of the cursor
	enum CursorStyle {
		block, /// a solid block over the position (like default xterm or many gui replace modes)
		underline, /// underlining the position (like the vga text mode default)
		bar, /// a bar on the left side of the cursor position (like gui insert modes)
	}

	// these can be overridden, but don't have to be
	TextAttributes defaultTextAttributes() {
		TextAttributes ta;

		ta.foregroundIndex = 256; // terminal.d uses this as Color.DEFAULT
		ta.backgroundIndex = 256;

		import std.process;
		// I'm using the environment for this because my programs and scripts
		// already know this variable and then it gets nicely inherited. It is
		// also easy to set without buggering with other arguments. So works for me.
		version(with_24_bit_color) {
			if(environment.get("ELVISBG") == "dark") {
				ta.foreground = Color.white;
				ta.background = Color.black;
			} else {
				ta.foreground = Color.black;
				ta.background = Color.white;
			}
		}
		if(environment.get("ELVISBG") == "dark") {
			defaultForeground = Color.white;
			defaultBackground = Color.black;
		} else {
			defaultForeground = Color.black;
			defaultBackground = Color.white;
		}

		return ta;
	}

	Color defaultForeground;
	Color defaultBackground;

	Color[256] palette;

	/// .
	static struct TextAttributes {
		align(1):
		bool bold() { return (attrStore & 1) ? true : false; } ///
		void bold(bool t) { attrStore &= ~1; if(t) attrStore |= 1; } ///

		bool blink() { return (attrStore & 2) ? true : false; } ///
		void blink(bool t) { attrStore &= ~2; if(t) attrStore |= 2; } ///

		bool invisible() { return (attrStore & 4) ? true : false; } ///
		void invisible(bool t) { attrStore &= ~4; if(t) attrStore |= 4; } ///

		bool inverse() { return (attrStore & 8) ? true : false; } ///
		void inverse(bool t) { attrStore &= ~8; if(t) attrStore |= 8; } ///

		bool underlined() { return (attrStore & 16) ? true : false; } ///
		void underlined(bool t) { attrStore &= ~16; if(t) attrStore |= 16; } ///

		bool italic() { return (attrStore & 32) ? true : false; } ///
		void italic(bool t) { attrStore &= ~32; if(t) attrStore |= 32; } ///

		bool strikeout() { return (attrStore & 64) ? true : false; } ///
		void strikeout(bool t) { attrStore &= ~64; if(t) attrStore |= 64; } ///

		bool faint() { return (attrStore & 128) ? true : false; } ///
		void faint(bool t) { attrStore &= ~128; if(t) attrStore |= 128; } ///

		// if the high bit here is set, you should use the full Color values if possible, and the value here sans the high bit if not
		ushort foregroundIndex; /// .
		ushort backgroundIndex; /// .

		version(with_24_bit_color) {
			Color foreground; /// .
			Color background; /// .
		}

		ubyte attrStore = 0;
	}

		//pragma(msg, TerminalCell.sizeof);
	/// represents one terminal cell
	align((void*).sizeof)
	static struct TerminalCell {
	align(1):
		private union {
			struct {
				dchar chStore = ' '; /// the character
				TextAttributes attributesStore; /// color, etc.
			}
			NonCharacterData nonCharacterDataStore; /// iff hasNonCharacterData
		}

		dchar ch() {
			assert(!hasNonCharacterData);
			return chStore;
		}
		void ch(dchar c) { 
			hasNonCharacterData = false;
			chStore = c;
		}
		ref TextAttributes attributes() {
			assert(!hasNonCharacterData);
			return attributesStore;
		}
		NonCharacterData nonCharacterData() {
			assert(hasNonCharacterData);
			return nonCharacterDataStore;
		}
		void nonCharacterData(NonCharacterData c) {
			hasNonCharacterData = true;
			nonCharacterDataStore = c;
		}

		ubyte attrStore = 1;  // just invalidated to start

		bool invalidated() { return (attrStore & 1) ? true : false; } /// if it needs to be redrawn
		void invalidated(bool t) { attrStore &= ~1; if(t) attrStore |= 1; } /// ditto

		bool selected() { return (attrStore & 2) ? true : false; } /// if it is currently selected by the user (for being copied to the clipboard)
		void selected(bool t) { attrStore &= ~2; if(t) attrStore |= 2; } /// ditto

		bool hasNonCharacterData() { return (attrStore & 4) ? true : false; } ///
		void hasNonCharacterData(bool t) { attrStore &= ~4; if(t) attrStore |= 4; }
	}

	/// Cursor position, zero based. (0,0) == upper left. (0, 1) == second row, first column.
	static struct CursorPosition {
		int x; /// .
		int y; /// .
		alias y row;
		alias x column;
	}

	// these public functions can be used to manipulate the terminal

	/// clear the screen
	void cls() {
		TerminalCell plain;
		plain.ch = ' ';
		plain.attributes = currentAttributes;
		plain.invalidated = true;
		foreach(i, ref cell; alternateScreenActive ? alternateScreen : normalScreen) {
			cell = plain;
		}
	}

	void makeSelectionOffsetsSane(ref int offsetStart, ref int offsetEnd) {
		auto buffer = &alternateScreen;

		if(offsetStart < 0)
			offsetStart = 0;
		if(offsetEnd < 0)
			offsetEnd = 0;
		if(offsetStart > (*buffer).length)
			offsetStart = cast(int) (*buffer).length;
		if(offsetEnd > (*buffer).length)
			offsetEnd = cast(int) (*buffer).length;

		// if it is backwards, we can flip it
		if(offsetEnd < offsetStart) {
			auto tmp = offsetStart;
			offsetStart = offsetEnd;
			offsetEnd = tmp;
		}
	}

	public string getPlainText(int offsetStart, int offsetEnd) {
		auto buffer = alternateScreenActive ? &alternateScreen : &normalScreen;

		makeSelectionOffsetsSane(offsetStart, offsetEnd);

		if(offsetStart == offsetEnd)
			return null;

		int x = offsetStart % screenWidth;
		int firstSpace = -1;
		string ret;
		foreach(cell; (*buffer)[offsetStart .. offsetEnd]) {
			ret ~= cell.ch;

			x++;
			if(x == screenWidth) {
				x = 0;
				if(firstSpace != -1) {
					// we ended with a bunch of spaces, let's replace them with a single newline so the next is more natural
					ret = ret[0 .. firstSpace];
					ret ~= "\n";
					firstSpace = -1;
				}
			} else {
				if(cell.ch == ' ' && firstSpace == -1)
					firstSpace = cast(int) ret.length - 1;
				else if(cell.ch != ' ')
					firstSpace = -1;
			}
		}
		if(firstSpace != -1) {
			bool allSpaces = true;
			foreach(item; ret[firstSpace .. $]) {
				if(item != ' ') {
					allSpaces = false;
					break;
				}
			}

			if(allSpaces)
				ret = ret[0 .. firstSpace];
		}

		return ret;
	}

	void scrollDown(int count = 1) {
		if(cursorY + 1 < screenHeight) {
			TerminalCell plain;
			plain.ch = ' ';
			plain.attributes = defaultTextAttributes();
			plain.invalidated = true;
			foreach(i; 0 .. count) {
				// FIXME: should that be cursorY or scrollZoneTop?
				for(int y = scrollZoneBottom; y > cursorY; y--)
				foreach(x; 0 .. screenWidth) {
					ASS[y][x] = ASS[y - 1][x];
					ASS[y][x].invalidated = true;
				}

				foreach(x; 0 .. screenWidth)
					ASS[cursorY][x] = plain;
			}
		}
	}

	void scrollUp(int count = 1) {
		if(cursorY + 1 < screenHeight) {
			TerminalCell plain;
			plain.ch = ' ';
			plain.attributes = defaultTextAttributes();
			plain.invalidated = true;
			foreach(i; 0 .. count) {
				// FIXME: should that be cursorY or scrollZoneBottom?
				for(int y = scrollZoneTop; y < cursorY; y++)
				foreach(x; 0 .. screenWidth) {
					ASS[y][x] = ASS[y + 1][x];
					ASS[y][x].invalidated = true;
				}

				foreach(x; 0 .. screenWidth)
					ASS[cursorY][x] = plain;
			}
		}
	}


	int readingExtensionData = -1;
	string extensionData;

	immutable(dchar[dchar])* characterSet = null; // null means use regular UTF-8

	bool readingEsc = false;
	ScopeBuffer!(ubyte, 1024) esc;
	/// sends raw input data to the terminal as if the application printf()'d it or it echoed or whatever
	void sendRawInput(in ubyte[] datain) {
		const(ubyte)[] data = datain;
	//import std.array;
	//assert(!readingEsc, replace(cast(string) esc, "\033", "\\"));
		again:
		foreach(didx, b; data) {
			if(readingExtensionData >= 0) {
				if(readingExtensionData == extensionMagicIdentifier.length) {
					if(b) {
						if(b != 13 && b != 10)
							extensionData ~= b;
					} else {
						readingExtensionData = -1;
						import std.base64;
						auto got = handleBinaryExtensionData(Base64.decode(extensionData));

						auto rep = got.representation;
						foreach(y; 0 .. got.height) {
							foreach(x; 0 .. got.width) {
								addOutput(rep[0]);
								rep = rep[1 .. $];
							}
							newLine(true);
						}
					}
				} else {
					if(b == extensionMagicIdentifier[readingExtensionData])
						readingExtensionData++;
					else {
						// put the data back into the buffer, if possible
						// (if the data was split across two packets, this may
						//  not be possible. but in that case, meh.)
						if(cast(int) didx - cast(int) readingExtensionData >= 0)
							data = data[didx - readingExtensionData .. $];
						readingExtensionData = -1;
						goto again;
					}
				}

				continue;
			}

			if(b == 0) {
				readingExtensionData = 0;
				extensionData = null;
				continue;
			}

			if(readingEsc) {
				if(b == 27) {
					// an esc in the middle of a sequence will
					// cancel the first one
					esc = null;
					continue;
				}

				if(b == 10) {
					readingEsc = false;
				}
				esc ~= b;

				if(esc.length == 1 && esc[0] == '7') {
					pushSavedCursor(cursorPosition);
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == 'M') {
					// reverse index
					esc = null;
					readingEsc = false;
					if(cursorY <= scrollZoneTop)
						scrollDown();
					else
						cursorY = cursorY - 1;
				} else if(esc.length == 1 && esc[0] == '=') {
					// application keypad
					esc = null;
					readingEsc = false;
				} else if(esc.length == 2 && esc[0] == '%' && esc[1] == 'G') {
					// UTF-8 mode
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == '8') {
					cursorPosition = popSavedCursor;
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == 'c') {
					// reset
					// FIXME
					esc = null;
					readingEsc = false;
				} else if(esc.length == 1 && esc[0] == '>') {
					// normal keypad
					esc = null;
					readingEsc = false;
				} else if(esc.length > 1 && (
					(esc[0] == '[' && (b >= 64 && b <= 126)) ||
					(esc[0] == ']' && b == '\007')))
				{
					tryEsc(esc[]);
					esc = null;
					readingEsc = false;
				} else if(esc.length == 3 && esc[0] == '%' && esc[1] == 'G') {
					// UTF-8 mode. ignored because we're always in utf-8 mode (though should we be?)
					esc = null;
					readingEsc = false;
				} else if(esc.length == 2 && esc[0] == ')') {
					// more character set selection. idk exactly how this works
					esc = null;
					readingEsc = false;
				} else if(esc.length == 2 && esc[0] == '(') {
					// xterm command for character set
					// FIXME: handling esc[1] == '0' would be pretty boss
					// and esc[1] == 'B' == united states
					if(esc[1] == '0')
						characterSet = &lineDrawingCharacterSet;
					else
						characterSet = null; // our default is UTF-8 and i don't care much about others anyway.

					esc = null;
					readingEsc = false;
				}
				continue;
			}

			if(b == 27) {
				readingEsc = true;
				debug if(esc.isNull && esc.length) {
					import std.stdio; writeln("discarding esc ", cast(string) esc[]);
				}
				esc = null;
				continue;
			}

			if(b == 13) {
				cursorX = 0;
				continue;
			}

			if(b == 7) {
				soundBell();
				continue;
			}

			if(b == 8) {
				cursorX = cursorX - 1;
				continue;
			}

			if(b == 9) {
				int howMany = 8 - (cursorX % 8);
				// so apparently it is just supposed to move the cursor.
				// it breaks mutt to output spaces
				cursorX = cursorX + howMany;
				//foreach(i; 0 .. howMany)
					//addOutput(' '); // FIXME: it would be nice to actually put a tab character there for copy/paste accuracy (ditto with newlines actually)
				continue;
			}

//			std.stdio.writeln("READ ", data[w]);
			addOutput(b);
		}
	}


	/// construct
	this(int width, int height) {
		// initialization
		currentAttributes = defaultTextAttributes();
		cursorColor = Color.white;

		palette[] = xtermPalette[];

		resizeTerminal(width, height);

		// update the other thing
		if(windowTitle.length == 0)
			windowTitle = "Terminal Emulator";
		changeWindowTitle(windowTitle);
		changeIconTitle(iconTitle);
		changeTextAttributes(currentAttributes);
	}


	private {
		TerminalCell[] scrollbackMainScreen;
		bool scrollbackCursorShowing;
		int scrollbackCursorX;
		int scrollbackCursorY;
		protected bool scrollingBack;

		int currentScrollback;
		int currentScrollbackX;
	}

	// FIXME: if it is resized while scrolling back, stuff can get messed up

	void scrollback(int delta, int deltaX = 0) {
		if(alternateScreenActive && !scrollingBack)
			return;

		if(!scrollingBack) {
			if(delta <= 0)
				return; // it does nothing to scroll down when not scrolling back
			startScrollback();
		}
		currentScrollback += delta;
		if(deltaX) {
			currentScrollbackX += deltaX;
			if(currentScrollbackX < 0) {
				currentScrollbackX = 0;
				scrollbackReflow = true;
			} else
				scrollbackReflow = false;
		}

		int max = cast(int) scrollbackBuffer.length - screenHeight;
		if(scrollbackReflow && max < 0) {
			foreach(line; scrollbackBuffer[])
				max += cast(int) line.length / screenWidth;
		}

		if(max < 0)
			max = 0;

		if(scrollbackReflow && currentScrollback > max) {
			foreach(line; scrollbackBuffer[])
				max += cast(int) line.length / screenWidth;
		}

		if(currentScrollback > max)
			currentScrollback = max;

		if(currentScrollback <= 0)
			endScrollback();
		else {
			cls();
			showScrollbackOnScreen(alternateScreen, currentScrollback, scrollbackReflow, currentScrollbackX);
		}
	}

	private void startScrollback() {
		if(scrollingBack)
			return;
		currentScrollback = 0;
		currentScrollbackX = 0;
		scrollingBack = true;
		scrollbackCursorX = cursorX;
		scrollbackCursorY = cursorY;
		scrollbackCursorShowing = cursorShowing;
		scrollbackMainScreen = alternateScreen.dup;
		alternateScreenActive = true;

		cursorShowing = false;
	}

	bool endScrollback() {
		if(!scrollingBack)
			return false;
		scrollingBack = false;
		cursorX = scrollbackCursorX;
		cursorY = scrollbackCursorY;
		cursorShowing = scrollbackCursorShowing;
		alternateScreen = scrollbackMainScreen;
		alternateScreenActive = false;
		return true;
	}

	private bool scrollbackReflow = true;
	public void toggleScrollbackWrap() {
		scrollbackReflow = !scrollbackReflow;
	}

	public void writeScrollbackToFile(string filename) {
		import std.stdio;
		auto file = File(filename, "wt");
		foreach(line; scrollbackBuffer[]) {
			foreach(c; line)
				file.write(c.ch); // I hope this is buffered
			file.writeln();
		}
	}

	private void showScrollbackOnScreen(ref TerminalCell[] screen, int howFar, bool reflow, int howFarX) {
		int start;

		cursorX = 0;
		cursorY = 0;

		int excess = 0;

		if(scrollbackReflow) {
			int numLines;
			int idx = cast(int) scrollbackBuffer.length - 1;
			foreach_reverse(line; scrollbackBuffer[]) {
				auto lineCount = 1 + line.length / screenWidth;
				numLines += lineCount;
				if(numLines >= (screenHeight + howFar)) {
					start = cast(int) idx;
					excess = numLines - (screenHeight + howFar);
					break;
				}
				idx--;
			}
		} else {
			auto termination = cast(int) scrollbackBuffer.length - howFar;
			if(termination < 0)
				termination = cast(int) scrollbackBuffer.length;

			start = termination - screenHeight;
			if(start < 0)
				start = 0;
		}

		TerminalCell overflowCell;
		overflowCell.ch = '\&raquo;';
		overflowCell.attributes.backgroundIndex = 3;
		overflowCell.attributes.foregroundIndex = 0;
		version(with_24_bit_color) {
			overflowCell.attributes.foreground = Color(40, 40, 40);
			overflowCell.attributes.background = Color.yellow;
		}

		outer: foreach(line; scrollbackBuffer[start .. $]) {
			if(excess) {
				line = line[excess * screenWidth .. $];
				excess = 0;
			}

			if(howFarX) {
				if(howFarX <= line.length)
					line = line[howFarX .. $];
				else
					line = null;
			}

			bool overflowed;
			foreach(cell; line) {
				cell.invalidated = true;
				if(overflowed)
					screen[cursorY * screenWidth + cursorX] = overflowCell;
				else
					screen[cursorY * screenWidth + cursorX] = cell;

				if(cursorX == screenWidth-1) {
					if(scrollbackReflow) {
						cursorX = 0;
						if(cursorY + 1 == screenHeight)
							break outer;
						cursorY = cursorY + 1;
					} else {
						overflowed = true;
					}
				} else
					cursorX = cursorX + 1;
			}
			if(cursorY + 1 == screenHeight)
				break;
			cursorY = cursorY + 1;
			cursorX = 0;
		}

		cursorX = 0;
	}

	protected bool cueScrollback;

	public void resizeTerminal(int w, int h) {
		if(w == screenWidth && h == screenHeight)
			return; // we're already good, do nothing to avoid wasting time and possibly losing a line (bash doesn't seem to like being told it "resized" to the same size)

		endScrollback(); // FIXME: hack

		screenWidth = w;
		screenHeight = h;

		normalScreen.length = screenWidth * screenHeight;
		alternateScreen.length = screenWidth * screenHeight;
		scrollZoneBottom = screenHeight - 1;

		// we need to make sure the state is sane all across the board, so first we'll clear everything...
		TerminalCell plain;
		plain.ch = ' ';
		plain.attributes = defaultTextAttributes;
		plain.invalidated = true;
		normalScreen[] = plain;
		alternateScreen[] = plain;

		// then, in normal mode, we'll redraw using the scrollback buffer
		//
		// if we're in the alternate screen though, keep it blank because
		// while redrawing makes sense in theory, odds are the program in
		// charge of the normal screen didn't get the resize signal.
		if(!alternateScreenActive)
			showScrollbackOnScreen(normalScreen, 0, true, 0);
		else
			cueScrollback = true;
		// but in alternate mode, it is the application's responsibility

		// the property ensures these are within bounds so this set just forces that
		cursorY = cursorY;
		cursorX = cursorX;
	}

	private CursorPosition popSavedCursor() {
		CursorPosition pos;
		//import std.stdio; writeln("popped");
		if(savedCursors.length) {
			pos = savedCursors[$-1];
			savedCursors = savedCursors[0 .. $-1];
			savedCursors.assumeSafeAppend(); // we never keep references elsewhere so might as well reuse the memory as much as we can
		}

		// If the screen resized after this was saved, it might be restored to a bad amount, so we need to sanity test.
		if(pos.x < 0)
			pos.x = 0;
		if(pos.y < 0)
			pos.y = 0;
		if(pos.x > screenWidth)
			pos.x = screenWidth - 1;
		if(pos.y > screenHeight)
			pos.y = screenHeight - 1;

		return pos;
	}

	private void pushSavedCursor(CursorPosition pos) {
		//import std.stdio; writeln("pushed");
		savedCursors ~= pos;
	}

	/* FIXME: i want these to be private */
	protected {
		TextAttributes currentAttributes;
		CursorPosition cursorPosition;
		CursorPosition[] savedCursors; // a stack
		CursorStyle cursorStyle;
		Color cursorColor;
		string windowTitle;
		string iconTitle;

		bool attentionDemanded;

		IndexedImage windowIcon;
		IndexedImage[] iconStack;

		string[] titleStack;

		bool bracketedPasteMode;
		bool mouseButtonTracking;
		private bool _mouseMotionTracking;
		bool mouseButtonReleaseTracking;
		bool mouseButtonMotionTracking;

		bool mouseMotionTracking() {
			return _mouseMotionTracking;
		}

		void mouseMotionTracking(bool b) {
			_mouseMotionTracking = b;
		}

		void allMouseTrackingOff() {
			mouseMotionTracking = false;
			mouseButtonTracking = false;
			mouseButtonReleaseTracking = false;
			mouseButtonMotionTracking = false;
		}

		bool wraparoundMode = true;

		bool alternateScreenActive;
		bool cursorShowing = true;

		bool reverseVideo;
		bool applicationCursorKeys;

		bool scrollingEnabled = true;
		int scrollZoneTop;
		int scrollZoneBottom;

		int screenWidth;
		int screenHeight;
		// assert(alternateScreen.length = screenWidth * screenHeight);
		TerminalCell[] alternateScreen;
		TerminalCell[] normalScreen;

		// the lengths can be whatever
		ScrollbackBuffer scrollbackBuffer;

		static struct ScrollbackBuffer {
			TerminalCell[][] backing;

			enum maxScrollback = 8192 / 2; // as a power of 2, i hope the compiler optimizes the % below to a simple bit mask...

			int start;
			int length_;

			size_t length() {
				return length_;
			}

			void opOpAssign(string op : "~")(TerminalCell[] line) {
				if(length_ < maxScrollback) {
					backing.assumeSafeAppend();
					backing ~= line;
					length_++;
				} else {
					backing[start] = line;
					start++;
					if(start == maxScrollback)
						start = 0;
				}
			}

			/*
			int opApply(scope int delegate(ref TerminalCell[]) dg) {
				foreach(ref l; backing)
					if(auto res = dg(l))
						return res;
				return 0;
			}

			int opApplyReverse(scope int delegate(size_t, ref TerminalCell[]) dg) {
				foreach_reverse(idx, ref l; backing)
					if(auto res = dg(idx, l))
						return res;
				return 0;
			}
			*/

			TerminalCell[] opIndex(int idx) {
				return backing[(start + idx) % maxScrollback];
			}

			ScrollbackBufferRange opSlice(int startOfIteration, Dollar end) {
				return ScrollbackBufferRange(&this, startOfIteration);
			}
			ScrollbackBufferRange opSlice() {
				return ScrollbackBufferRange(&this, 0);
			}

			static struct ScrollbackBufferRange {
				ScrollbackBuffer* item;
				int position;
				int remaining;
				this(ScrollbackBuffer* item, int startOfIteration) {
					this.item = item;
					position = startOfIteration;
					remaining = cast(int) item.length - startOfIteration;

				}

				TerminalCell[] front() { return (*item)[position]; }
				bool empty() { return remaining <= 0; }
				void popFront() {
					position++;
					remaining--;
				}

				TerminalCell[] back() { return (*item)[remaining - 1 - position]; }
				void popBack() {
					remaining--;
				}
			}

			static struct Dollar {};
			Dollar opDollar() { return Dollar(); }

		}

		struct Helper2 {
			size_t row;
			TerminalEmulator t;
			this(TerminalEmulator t, size_t row) {
				this.t = t;
				this.row = row;
			}

			ref TerminalCell opIndex(size_t cell) {
				auto thing = t.alternateScreenActive ? &(t.alternateScreen) : &(t.normalScreen);
				return (*thing)[row * t.screenWidth + cell];
			}
		}

		struct Helper {
			TerminalEmulator t;
			this(TerminalEmulator t) {
				this.t = t;
			}

			Helper2 opIndex(size_t row) {
				return Helper2(t, row);
			}
		}

		@property Helper ASS() {
			return Helper(this);
		}

		@property int cursorX() { return cursorPosition.x; }
		@property int cursorY() { return cursorPosition.y; }
		@property void cursorX(int x) {
			if(x < 0)
				x = 0;
			if(x >= screenWidth)
				x = screenWidth - 1;
			cursorPosition.x = x;
		}
		@property void cursorY(int y) {
			if(y < 0)
				y = 0;
			if(y >= screenHeight)
				y = screenHeight - 1;
			cursorPosition.y = y;
		}

		void addOutput(string b) {
			foreach(c; b)
				addOutput(c);
		}

		TerminalCell[] currentScrollbackLine;
		int scrollbackWrappingAt = 0;
		dchar utf8Sequence;
		int utf8BytesRemaining;
		int currentUtf8Shift;
		bool newLineOnNext;
		void addOutput(ubyte b) {
			// this takes in bytes at a time, but since the input encoding is assumed to be UTF-8, we need to gather the bytes
			if(utf8BytesRemaining == 0) {
				// we're at the beginning of a sequence
				utf8Sequence = 0;
				if(b < 128) {
					utf8Sequence = cast(dchar) b;
					// one byte thing, do nothing more...
				} else {
					// the number of bytes in the sequence is the number of set bits in the first byte...
					uint shifted =0;
					bool there = false;
					ubyte checkingBit = 7;
					while(checkingBit) {
						if(!there && b & (1 << checkingBit))
							utf8BytesRemaining++;
						else
							there = true;
						if(there)
							shifted |= b & (1 << checkingBit);
						checkingBit--;
					}
					utf8BytesRemaining--; // since this current byte counts too
					currentUtf8Shift = utf8BytesRemaining * 6;

					shifted <<= (currentUtf8Shift + checkingBit);
					utf8Sequence = cast(dchar) shifted;
				}
			} else {
				// add this to the byte we're doing right now...
				utf8BytesRemaining--;
				currentUtf8Shift -= 6;
				if(!(b & 0b11000000) == 0b10000000) {
					// invalid utf-8 sequence,
					// discard it and try to continue
					utf8BytesRemaining = 0;
					return;
				}
				uint shifted = b;
				shifted &= 0b00111111;
				shifted <<= currentUtf8Shift;
				utf8Sequence |= shifted;
			}

			if(utf8BytesRemaining)
				return; // not enough data yet, wait for more before displaying anything

			if(utf8Sequence == 10) {
				newLineOnNext = false;
				auto cx = cursorX; // FIXME: this cx thing is a hack, newLine should prolly just do the right thing

				/*
				TerminalCell tc;
				tc.ch = utf8Sequence;
				tc.attributes = currentAttributes;
				tc.invalidated = true;
				addOutput(tc);
				*/

				newLine(true);
				cursorX = cx;
			} else {
				if(newLineOnNext) {
					newLineOnNext = false;
					// only if we're still on the right side...
					if(cursorX == screenWidth - 1)
						newLine(false);
				}
				TerminalCell tc;

				if(characterSet !is null) {
					if(auto replacement = utf8Sequence in *characterSet)
						utf8Sequence = *replacement;
				}
				tc.ch = utf8Sequence;
				tc.attributes = currentAttributes;
				tc.invalidated = true;

				addOutput(tc);
			}
		}

		bool insertMode = false;
		void newLine(bool commitScrollback) {
			if(!alternateScreenActive && commitScrollback) {
				// I am limiting this because obscenely long lines are kinda useless anyway and
				// i don't want it to eat excessive memory when i spam some thing accidentally
				if(currentScrollbackLine.length < 1024)
					scrollbackBuffer ~= currentScrollbackLine;
				else
					scrollbackBuffer ~= currentScrollbackLine[0 .. 1024];

				currentScrollbackLine = null;
				currentScrollbackLine.reserve(64);
				scrollbackWrappingAt = 0;
			}

			cursorX = 0;
			if(scrollingEnabled && cursorY >= scrollZoneBottom) {
				size_t idx = scrollZoneTop * screenWidth;

				// When we scroll up, we need to update the selection position too
				if(selectionStart != selectionEnd) {
					selectionStart -= screenWidth;
					selectionEnd -= screenWidth;
				}
				foreach(l; scrollZoneTop .. scrollZoneBottom) {
					if(alternateScreenActive) {
						if(idx + screenWidth * 2 > alternateScreen.length)
							break;
						alternateScreen[idx .. idx + screenWidth] = alternateScreen[idx + screenWidth .. idx + screenWidth * 2];
					} else {
						if(idx + screenWidth * 2 > normalScreen.length)
							break;
						normalScreen[idx .. idx + screenWidth] = normalScreen[idx + screenWidth .. idx + screenWidth * 2];
					}
					idx += screenWidth;
				}
				/*
				foreach(i; 0 .. screenWidth) {
					if(alternateScreenActive) {
						alternateScreen[idx] = alternateScreen[idx + screenWidth];
						alternateScreen[idx].invalidated = true;
					} else {
						normalScreen[idx] = normalScreen[idx + screenWidth];
						normalScreen[idx].invalidated = true;
					}
					idx++;
				}
				*/
				/*
				foreach(i; 0 .. screenWidth) {
					if(alternateScreenActive) {
						alternateScreen[idx].ch = ' ';
						alternateScreen[idx].attributes = currentAttributes;
						alternateScreen[idx].invalidated = true;
					} else {
						normalScreen[idx].ch = ' ';
						normalScreen[idx].attributes = currentAttributes;
						normalScreen[idx].invalidated = true;
					}
					idx++;
				}
				*/

				TerminalCell plain;
				plain.ch = ' ';
				plain.attributes = currentAttributes;
				if(alternateScreenActive) {
					alternateScreen[idx .. idx + screenWidth] = plain;
				} else {
					normalScreen[idx .. idx + screenWidth] = plain;
				}
			} else {
				if(insertMode)
					scrollDown();
				else
					cursorY = cursorY + 1;
			}

			invalidateAll = true;
		}

		protected bool invalidateAll;

		void clearSelection() {
			foreach(ref tc; alternateScreenActive ? alternateScreen : normalScreen)
				if(tc.selected) {
					tc.selected = false;
					tc.invalidated = true;
				}
			selectionStart = 0;
			selectionEnd = 0;
		}

		void addOutput(TerminalCell tc) {
			if(alternateScreenActive) {
				if(alternateScreen[cursorY * screenWidth + cursorX].selected) {
					clearSelection();
				}
				alternateScreen[cursorY * screenWidth + cursorX] = tc;
			} else {
				if(normalScreen[cursorY * screenWidth + cursorX].selected) {
					clearSelection();
				}
				// FIXME: make this more efficient if it is writing the same thing,
				// then it need not be invalidated. Same with above for the alt screen
				normalScreen[cursorY * screenWidth + cursorX] = tc;

				TerminalCell plain;
				plain.ch = ' ';
				plain.attributes = currentAttributes;
				int lol = cursorX + scrollbackWrappingAt;
				while(lol >= currentScrollbackLine.length)
					currentScrollbackLine ~= plain;
				currentScrollbackLine[lol] = tc;
			}
			// FIXME: the wraparoundMode seems to help gnu screen but then it doesn't go away properly and that messes up bash...
			//if(wraparoundMode && cursorX == screenWidth - 1) {
			if(cursorX == screenWidth - 1) {
				// FIXME: should this check the scrolling zone instead?
				newLineOnNext = true;

				//if(!alternateScreenActive || cursorY < screenHeight - 1)
					//newLine(false);
				scrollbackWrappingAt = cast(int) currentScrollbackLine.length;
			} else
				cursorX = cursorX + 1;

		}

		void tryEsc(ubyte[] esc) {
			bool[2] sidxProcessed;
			int[][2] argsAtSidx;
			int[12][2] argsAtSidxBuffer;

			int[12][4] argsBuffer;
			int argsBufferLocation;

			int[] getArgsBase(int sidx, int[] defaults) {
				assert(sidx == 1 || sidx == 2);

				if(sidxProcessed[sidx - 1]) {
					int[] bfr = argsBuffer[argsBufferLocation++][];
					if(argsBufferLocation == argsBuffer.length)
						argsBufferLocation = 0;
					bfr[0 .. defaults.length] = defaults[];
					foreach(idx, v; argsAtSidx[sidx - 1])
						if(v != int.min)
							bfr[idx] = v;
					return bfr[0 .. max(argsAtSidx[sidx - 1].length, defaults.length)];
				}

				auto argsSection = cast(char[]) esc[sidx .. $-1];
				int[] args = argsAtSidxBuffer[sidx - 1][];

				import std.string : split;
				import std.conv : to;
				int lastIdx = 0;

				foreach(i, arg; split(argsSection, ";")) {
					int value;
					if(arg.length)
						value = to!int(arg);
					else
						value = int.min; // defaults[i];

					if(args.length > i)
						args[i] = value;
					else
						assert(0);
					lastIdx++;
				}

				argsAtSidx[sidx - 1] = args[0 .. lastIdx];
				sidxProcessed[sidx - 1] = true;

				return getArgsBase(sidx, defaults);
			}
			int[] getArgs(int[] defaults...) {
				return getArgsBase(1, defaults);
			}

			// FIXME
			// from  http://invisible-island.net/xterm/ctlseqs/ctlseqs.html
			// check out this section: "Window manipulation (from dtterm, as well as extensions)"
			// especially the title stack, that should rock
			/*
P s = 2 2 ; 0 → Save xterm icon and window title on stack.
P s = 2 2 ; 1 → Save xterm icon title on stack.
P s = 2 2 ; 2 → Save xterm window title on stack.
P s = 2 3 ; 0 → Restore xterm icon and window title from stack.
P s = 2 3 ; 1 → Restore xterm icon title from stack.
P s = 2 3 ; 2 → Restore xterm window title from stack.

			*/

			if(esc[0] == ']' && esc.length > 1) {
				int idx = -1;
				foreach(i, e; esc)
					if(e == ';') {
						idx = cast(int) i;
						break;
					}
				if(idx != -1) {
					auto arg = cast(char[]) esc[idx + 1 .. $-1];
					switch(cast(char[]) esc[1..idx]) {
						case "0":
							// icon name and window title
							windowTitle = iconTitle = arg.idup;
							changeWindowTitle(windowTitle);
							changeIconTitle(iconTitle);
						break;
						case "1":
							// icon name
							iconTitle = arg.idup;
							changeIconTitle(iconTitle);
						break;
						case "2":
							// window title
							windowTitle = arg.idup;
							changeWindowTitle(windowTitle);
						break;
						case "10":
							// change default text foreground color
						break;
						case "11":
							// change gui background color
						break;
						case "12":
							if(arg.length)
								arg = arg[1 ..$]; // skip past the thing
							if(arg.length) {
								cursorColor = Color.fromString(arg);
								foreach(ref p; cursorColor.components[0 .. 3])
									p ^= 0xff;
							} else
								cursorColor = Color.white;
						break;
						case "50":
							// change font
						break;
						case "52":
							// copy/paste control
							// echo -e "\033]52;p;?\007"
							// the p == primary
							// the data after it is either base64 stuff to copy or ? to request a paste

							if(arg == "p;?") {
								// i'm using this to request a paste. not quite compatible with xterm, but kinda
								// because xterm tends not to answer anyway.
								pasteFromPrimary(&sendPasteData);
							} else if(arg.length > 2 && arg[0 .. 2] == "p;") {
								auto info = arg[2 .. $];
								try {
									import std.base64;
									auto data = Base64.decode(info);
									copyToPrimary(cast(string) data);
								} catch(Exception e)  {}
							}

							if(arg == "c;?") {
								// i'm using this to request a paste. not quite compatible with xterm, but kinda
								// because xterm tends not to answer anyway.
								pasteFromClipboard(&sendPasteData);
							} else if(arg.length > 2 && arg[0 .. 2] == "c;") {
								auto info = arg[2 .. $];
								try {
									import std.base64;
									auto data = Base64.decode(info);
									copyToClipboard(cast(string) data);
								} catch(Exception e)  {}
							}

						break;
						case "4":
							// palette change or query
							        // set color #0 == black
							// echo -e '\033]4;0;black\007'
							/*
								echo -e '\033]4;9;?\007' ; cat

								^[]4;9;rgb:ffff/0000/0000^G
							*/

							// FIXME: if the palette changes, we should redraw so the change is immediately visible (as if we were using a real palette)
						break;
						case "104":
							// palette reset
							// reset color #0
							// echo -e '\033[104;0\007'
						break;
						/* Extensions */
						case "5000":
							// change window icon (send a base64 encoded image or something)
							/*
								The format here is width and height as a single char each
									'0'-'9' == 0-9
									'a'-'z' == 10 - 36
									anything else is invalid
								
								then a palette in hex rgba format (8 chars each), up to 26 entries

								then a capital Z

								if a palette entry == 'P', it means pull from the current palette (FIXME not implemented)

								then 256 characters between a-z (must be lowercase!) which are the palette entries for
								the pixels, top to bottom, left to right, so the image is 16x16. if it ends early, the
								rest of the data is assumed to be zero

								you can also do e.g. 22a, which means repeat a 22 times for some RLE.

								anything out of range aborts the operation
							*/
							auto img = readSmallTextImage(arg);
							windowIcon = img;
							changeWindowIcon(img);
						break;
						case "5001":
							// demand attention
							attentionDemanded = true;
							demandAttention();
						break;
						default:
							unknownEscapeSequence("" ~ cast(char) esc[1]);
					}
				}
			} else if(esc[0] == '[' && esc.length > 1) {
				switch(esc[$-1]) {
					case 'Z':
						// CSI Ps Z  Cursor Backward Tabulation Ps tab stops (default = 1) (CBT).
						// FIXME?
					break;
					case 'n':
						switch(esc[$-2]) {
							import std.string;
							// request status report, reply OK
							case '5': sendToApplication("\033[0n"); break;
							// request cursor position
							case '6': sendToApplication(format("\033[%d;%dR", cursorY + 1, cursorX + 1)); break;
							default: unknownEscapeSequence(cast(string) esc);
						}
					break;
					case 'A': if(cursorY) cursorY = cursorY - getArgs(1)[0]; break;
					case 'B': if(cursorY != this.screenHeight - 1) cursorY = cursorY + getArgs(1)[0]; break;
					case 'D': if(cursorX) cursorX = cursorX - getArgs(1)[0]; break;
					case 'C': if(cursorX != this.screenWidth - 1) cursorX = cursorX + getArgs(1)[0]; break;

					case 'd': cursorY = getArgs(1)[0]-1; break;

					case 'E': cursorY = cursorY + getArgs(1)[0]; cursorX = 0; break;
					case 'F': cursorY = cursorY - getArgs(1)[0]; cursorX = 0; break;
					case 'G': cursorX = getArgs(1)[0] - 1; break;
					case 'H':
						auto got = getArgs(1, 1);
						cursorX = got[1] - 1;
						cursorY = got[0] - 1;
						newLineOnNext = false;
					break;
					case 'L':
						// insert lines
						scrollDown(getArgs(1)[0]);
					break;
					case 'M':
						// delete lines
						if(cursorY + 1 < screenHeight) {
							TerminalCell plain;
							plain.ch = ' ';
							plain.attributes = defaultTextAttributes();
							foreach(i; 0 .. getArgs(1)[0]) {
								foreach(y; cursorY .. scrollZoneBottom)
								foreach(x; 0 .. screenWidth) {
									ASS[y][x] = ASS[y + 1][x];
									ASS[y][x].invalidated = true;
								}
								foreach(x; 0 .. screenWidth) {
									ASS[scrollZoneBottom][x] = plain;
								}
							}
						}
					break;
					case 'K':
						auto arg = getArgs(0)[0];
						int start, end;
						if(arg == 0) {
							// clear from cursor to end of line
							start = cursorX;
							end = this.screenWidth;
						} else if(arg == 1) {
							// clear from cursor to beginning of line
							start = 0;
							end = cursorX + 1;
						} else if(arg == 2) {
							// clear entire line
							start = 0;
							end = this.screenWidth;
						}

						TerminalCell plain;
						plain.ch = ' ';
						plain.attributes = currentAttributes;

						for(int i = start; i < end; i++) {
							if(ASS[cursorY][i].selected)
								clearSelection();
							ASS[cursorY]
								[i] = plain;
						}
					break;
					case 's':
						pushSavedCursor(cursorPosition);
					break;
					case 'u':
						cursorPosition = popSavedCursor();
					break;
					case 'g':
						auto arg = getArgs(0)[0];
						TerminalCell plain;
						plain.ch = ' ';
						plain.attributes = currentAttributes;
						if(arg == 0) {
							// clear current column
							for(int i = 0; i < this.screenHeight; i++)
								ASS[i]
									[cursorY] = plain;
						} else if(arg == 3) {
							// clear all
							cls();
						}
					break;
					case 'q':
						// xterm also does blinks on the odd numbers (x-1)
						if(esc == "[0 q")
							cursorStyle = CursorStyle.block; // FIXME: restore default
						if(esc == "[2 q")
							cursorStyle = CursorStyle.block;
						else if(esc == "[4 q")
							cursorStyle = CursorStyle.underline;
						else if(esc == "[6 q")
							cursorStyle = CursorStyle.bar;

						changeCursorStyle(cursorStyle);
					break;
					case 't':
						// window commands
						// i might support more of these but for now i just want the stack stuff.

						auto args = getArgs(0, 0);
						if(args[0] == 22) {
							// save window title to stack
							// xterm says args[1] should tell if it is the window title, the icon title, or both, but meh
							titleStack ~= windowTitle;
							iconStack ~= windowIcon;
						} else if(args[0] == 23) {
							// restore from stack
							if(titleStack.length) {
								windowTitle = titleStack[$ - 1];
								changeWindowTitle(titleStack[$ - 1]);
								titleStack = titleStack[0 .. $ - 1];
							}

							if(iconStack.length) {
								windowIcon = iconStack[$ - 1];
								changeWindowIcon(iconStack[$ - 1]);
								iconStack = iconStack[0 .. $ - 1];
							}
						}
					break;
					case 'm':
						argsLoop: foreach(argIdx, arg; getArgs(0))
						switch(arg) {
							case 0:
							// normal
								currentAttributes = defaultTextAttributes;
							break;
							case 1:
								currentAttributes.bold = true;
							break;
							case 2:
								currentAttributes.faint = true;
							break;
							case 3:
								currentAttributes.italic = true;
							break;
							case 4:
								currentAttributes.underlined = true;
							break;
							case 5:
								currentAttributes.blink = true;
							break;
							case 6:
								// rapid blink, treating the same as regular blink
								currentAttributes.blink = true;
							break;
							case 7:
								currentAttributes.inverse = true;
							break;
							case 8:
								currentAttributes.invisible = true;
							break;
							case 9:
								currentAttributes.strikeout = true;
							break;
							case 10:
								// primary font
							break;
							case 11: .. case 19:
								// alternate fonts
							break;
							case 20:
								// Fraktur font
							break;
							case 21:
								// bold off and doubled underlined
							break;
							case 22:
								currentAttributes.bold = false;
								currentAttributes.faint = false;
							break;
							case 23:
								currentAttributes.italic = false;
							break;
							case 24:
								currentAttributes.underlined = false;
							break;
							case 25:
								currentAttributes.blink = false;
							break;
							case 26:
								// reserved
							break;
							case 27:
								currentAttributes.inverse = false;
							break;
							case 28:
								currentAttributes.invisible = false;
							break;
							case 29:
								currentAttributes.strikeout = false;
							break;
							case 30:
							..
							case 37:
							// set foreground color
								/*
								Color nc;
								ubyte multiplier = currentAttributes.bold ? 255 : 127;
								nc.r = cast(ubyte)((arg - 30) & 1) * multiplier;
								nc.g = cast(ubyte)(((arg - 30) & 2)>>1) * multiplier;
								nc.b = cast(ubyte)(((arg - 30) & 4)>>2) * multiplier;
								nc.a = 255;
								*/
								currentAttributes.foregroundIndex = cast(ubyte)(arg - 30);
								version(with_24_bit_color)
								currentAttributes.foreground = palette[arg-30 + (currentAttributes.bold ? 8 : 0)];
							break;
							case 38:
								// xterm 256 color set foreground color
								auto args = getArgs()[argIdx + 1 .. $];
								if(args.length > 3 && args[0] == 2) {
									// set color to closest match in palette. but since we have full support, we'll just take it directly
									auto fg = Color(args[1], args[2], args[3]);
									version(with_24_bit_color)
										currentAttributes.foreground = fg;
									// and try to find a low default palette entry for maximum compatibility
									// 0x8000 == approximation
									currentAttributes.foregroundIndex = 0x8000 | cast(ushort) findNearestColor(xtermPalette[0 .. 16], fg);
								} else if(args.length > 1 && args[0] == 5) {
									// set to palette index
									version(with_24_bit_color)
										currentAttributes.foreground = palette[args[1]];
									currentAttributes.foregroundIndex = cast(ushort) args[1];
								}
								break argsLoop;
							case 39:
							// default foreground color
								auto dflt = defaultTextAttributes();

								version(with_24_bit_color)
									currentAttributes.foreground = dflt.foreground;
								currentAttributes.foregroundIndex = dflt.foregroundIndex;
							break;
							case 40:
							..
							case 47:
							// set background color
								/*
								Color nc;
								nc.r = cast(ubyte)((arg - 40) & 1) * 255;
								nc.g = cast(ubyte)(((arg - 40) & 2)>>1) * 255;
								nc.b = cast(ubyte)(((arg - 40) & 4)>>2) * 255;
								nc.a = 255;
								*/

								currentAttributes.backgroundIndex = cast(ubyte)(arg - 40);
								//currentAttributes.background = nc;
								version(with_24_bit_color)
									currentAttributes.background = palette[arg-40];
							break;
							case 48:
								// xterm 256 color set background color
								auto args = getArgs()[argIdx + 1 .. $];
								if(args.length > 3 && args[0] == 2) {
									// set color to closest match in palette. but since we have full support, we'll just take it directly
									auto bg = Color(args[1], args[2], args[3]);
									version(with_24_bit_color)
										currentAttributes.background = Color(args[1], args[2], args[3]);

									// and try to find a low default palette entry for maximum compatibility
									// 0x8000 == this is an approximation
									currentAttributes.backgroundIndex = 0x8000 | cast(ushort) findNearestColor(xtermPalette[0 .. 8], bg);
								} else if(args.length > 1 && args[0] == 5) {
									// set to palette index
									version(with_24_bit_color)
										currentAttributes.background = palette[args[1]];
									currentAttributes.backgroundIndex = cast(ushort) args[1];
								}

								break argsLoop;
							case 49:
							// default background color
								auto dflt = defaultTextAttributes();

								version(with_24_bit_color)
									currentAttributes.background = dflt.background;
								currentAttributes.backgroundIndex = dflt.backgroundIndex;
							break;
							case 51:
								// framed
							break;
							case 52:
								// encircled
							break;
							case 53:
								// overlined
							break;
							case 54:
								// not framed or encircled
							break;
							case 55:
								// not overlined
							break;
							case 90: .. case 97:
								// high intensity foreground color
							break;
							case 100: .. case 107:
								// high intensity background color
							break;
							default:
								unknownEscapeSequence(cast(string) esc);
						}
					break;
					case 'J':
						// erase in display
						auto arg = getArgs(0)[0];
						switch(arg) {
							case 0:
								TerminalCell plain;
								plain.ch = ' ';
								plain.attributes = currentAttributes;
								// erase below
								foreach(i; cursorY * screenWidth + cursorX .. screenWidth * screenHeight) {
									if(alternateScreenActive)
										alternateScreen[i] = plain;
									else
										normalScreen[i] = plain;
								}
							break;
							case 1:
								// erase above
								unknownEscapeSequence("FIXME");
							break;
							case 2:
								// erase all
								cls();
							break;
							default: unknownEscapeSequence(cast(string) esc);
						}
					break;
					case 'r':
						if(esc[1] != '?') {
							// set scrolling zone
							// default should be full size of window
							auto args = getArgs(1, screenHeight);

							scrollZoneTop = args[0] - 1;
							scrollZoneBottom = args[1] - 1;
						} else {
							// restore... something FIXME
						}
					break;
					case 'h':
						if(esc[1] != '?')
						foreach(arg; getArgs())
						switch(arg) {
							case 4:
								insertMode = true;
							break;
							case 34:
								// no idea. vim inside screen sends it
							break;
							default: unknownEscapeSequence(cast(string) esc);
						}
						else
					//import std.stdio; writeln("h magic ", cast(string) esc);
						foreach(arg; getArgsBase(2, null))
							switch(arg) {
								case 1:
									// application cursor keys
									applicationCursorKeys = true;
								break;
								case 3:
									// 132 column mode
								break;
								case 4:
									// smooth scroll
								break;
								case 5:
									// reverse video
									reverseVideo = true;
								break;
								case 6:
									// origin mode
								break;
								case 7:
									// wraparound mode
									wraparoundMode = false;
									// FIXME: wraparoundMode i think is supposed to be off by default but then bash doesn't work right so idk, this gives the best results
								break;
								case 9:
									allMouseTrackingOff();
									mouseButtonTracking = true;
								break;
								case 12:
									// start blinking cursor
								break;
								case 1034:
									// meta keys????
								break;
								case 1049:
									// Save cursor as in DECSC and use Alternate Screen Buffer, clearing it first.
									alternateScreenActive = true;
									pushSavedCursor(cursorPosition);
									cls();
								break;
								case 1000:
									// send mouse X&Y on button press and release
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
								break;
								case 1001: // hilight tracking, this is kinda weird so i don't think i want to implement it
								break;
								case 1002:
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
									mouseButtonMotionTracking = true;
									// use cell motion mouse tracking
								break;
								case 1003:
									// ALL motion is sent
									allMouseTrackingOff();
									mouseButtonTracking = true;
									mouseButtonReleaseTracking = true;
									mouseMotionTracking = true;
								break;
								case 1005:
									// enable utf-8 mouse mode
									/*
UTF-8 (1005)
          This enables UTF-8 encoding for Cx and Cy under all tracking
          modes, expanding the maximum encodable position from 223 to
          2015.  For positions less than 95, the resulting output is
          identical under both modes.  Under extended mouse mode, posi-
          tions greater than 95 generate "extra" bytes which will con-
          fuse applications which do not treat their input as a UTF-8
          stream.  Likewise, Cb will be UTF-8 encoded, to reduce confu-
          sion with wheel mouse events.
          Under normal mouse mode, positions outside (160,94) result in
          byte pairs which can be interpreted as a single UTF-8 charac-
          ter; applications which do treat their input as UTF-8 will
          almost certainly be confused unless extended mouse mode is
          active.
          This scheme has the drawback that the encoded coordinates will
          not pass through luit unchanged, e.g., for locales using non-
          UTF-8 encoding.
									*/
								break;
								case 1006:
								/*
SGR (1006)
          The normal mouse response is altered to use CSI < followed by
          semicolon-separated encoded button value, the Cx and Cy ordi-
          nates and a final character which is M  for button press and m
          for button release.
          o The encoded button value in this case does not add 32 since
            that was useful only in the X10 scheme for ensuring that the
            byte containing the button value is a printable code.
          o The modifiers are encoded in the same way.
          o A different final character is used for button release to
            resolve the X10 ambiguity regarding which button was
            released.
          The highlight tracking responses are also modified to an SGR-
          like format, using the same SGR-style scheme and button-encod-
          ings.
								*/
								break;
								case 1015:
								/*
URXVT (1015)
          The normal mouse response is altered to use CSI followed by
          semicolon-separated encoded button value, the Cx and Cy ordi-
          nates and final character M .
          This uses the same button encoding as X10, but printing it as
          a decimal integer rather than as a single byte.
          However, CSI M  can be mistaken for DL (delete lines), while
          the highlight tracking CSI T  can be mistaken for SD (scroll
          down), and the Window manipulation controls.  For these rea-
          sons, the 1015 control is not recommended; it is not an
          improvement over 1005.
								*/
								break;
								case 1048:
									pushSavedCursor(cursorPosition);
								break;
								case 2004:
									bracketedPasteMode = true;
								break;
								case 1047:
								case 47:
									alternateScreenActive = true;
									cls();
								break;
								case 25:
									cursorShowing = true;
								break;
								/* Extensions */
								default: unknownEscapeSequence(cast(string) esc);
							}
					break;
					case 'p':
						// it is asking a question... and tbh i don't care.
					break;
					case 'l':
					//import std.stdio; writeln("l magic ", cast(string) esc);
						if(esc[1] != '?')
						foreach(arg; getArgs())
						switch(arg) {
							case 4:
								insertMode = false;
							break;
							case 34:
								// no idea. vim inside screen sends it
							break;
							case 1005:
								// turn off utf-8 mouse
							break;
							case 1006:
								// turn off sgr mouse
							break;
							case 1015:
								// turn off urxvt mouse
							break;
							default: unknownEscapeSequence(cast(string) esc);
						}
						else
						foreach(arg; getArgsBase(2, null))
							switch(arg) {
								case 1:
									// normal cursor keys
									applicationCursorKeys = false;
								break;
								case 3:
									// 80 column mode
								break;
								case 4:
									// smooth scroll
								break;
								case 5:
									// normal video
									reverseVideo = false;
								break;
								case 6:
									// normal cursor mode
								break;
								case 7:
									// wraparound mode
									wraparoundMode = true;
								break;
								case 12:
									// stop blinking cursor
								break;
								case 1034:
									// meta keys????
								break;
								case 1049:
									cursorPosition = popSavedCursor;
									wraparoundMode = true;

									returnToNormalScreen();
								break;
								case 1001: // hilight tracking, this is kinda weird so i don't think i want to implement it
								break;
								case 9:
								case 1000:
								case 1002:
								case 1003:
									allMouseTrackingOff();
								break;
								case 1048:
									cursorPosition = popSavedCursor;
								break;
								case 2004:
									bracketedPasteMode = false;
								break;
								case 1047:
								case 47:
									returnToNormalScreen();
								break;
								case 25:
									cursorShowing = false;
								break;
								default: unknownEscapeSequence(cast(string) esc);
							}
					break;
					case 'X':
						// erase characters
						auto count = getArgs(1)[0];
						TerminalCell plain;
						plain.ch = ' ';
						plain.attributes = currentAttributes;
						foreach(cnt; 0 .. count) {
							ASS[cursorY][cnt + cursorX] = plain;
						}
					break;
					case 'S':
						auto count = getArgs(1)[0];
						// scroll up
						scrollUp(count);
					break;
					case 'T':
						auto count = getArgs(1)[0];
						// scroll down
						scrollDown(count);
					break;
					case 'P':
						auto count = getArgs(1)[0];
						// delete characters

						foreach(cnt; 0 .. count) {
							for(int i = cursorX; i < this.screenWidth-1; i++) {
								if(ASS[cursorY][i].selected)
									clearSelection();
								ASS[cursorY][i] = ASS[cursorY][i + 1];
								ASS[cursorY][i].invalidated = true;
							}

							if(ASS[cursorY][this.screenWidth - 1].selected)
								clearSelection();
							ASS[cursorY][this.screenWidth-1].ch = ' ';
							ASS[cursorY][this.screenWidth-1].invalidated = true;
						}
					break;
					case '@':
						// insert blank characters
						auto count = getArgs(1)[0];
						foreach(idx; 0 .. count) {
							for(int i = this.screenWidth - 1; i > cursorX; i--) {
								ASS[cursorY][i] = ASS[cursorY][i - 1];
								ASS[cursorY][i].invalidated = true;
							}
							ASS[cursorY][cursorX].ch = ' ';
							ASS[cursorY][cursorX].invalidated = true;
						}
					break;
					case 'c':
						// send device attributes
						// FIXME: what am i supposed to do here?
						sendToApplication("\033[>0;138;0c");
					break;
					default:
						// [42\esc] seems to have gotten here once somehow
						// also [24\esc]
						unknownEscapeSequence("" ~ cast(string) esc);
				}
			} else {
				unknownEscapeSequence(cast(string) esc);
			}
		}
	}
}

// These match the numbers in terminal.d, so you can just cast it back and forth
// and the names match simpledisplay.d so you can convert that automatically too
enum TerminalKey : int {
	Escape = 0x1b,// + 0xF0000, /// .
	F1 = 0x70,// + 0xF0000, /// .
	F2 = 0x71,// + 0xF0000, /// .
	F3 = 0x72,// + 0xF0000, /// .
	F4 = 0x73,// + 0xF0000, /// .
	F5 = 0x74,// + 0xF0000, /// .
	F6 = 0x75,// + 0xF0000, /// .
	F7 = 0x76,// + 0xF0000, /// .
	F8 = 0x77,// + 0xF0000, /// .
	F9 = 0x78,// + 0xF0000, /// .
	F10 = 0x79,// + 0xF0000, /// .
	F11 = 0x7A,// + 0xF0000, /// .
	F12 = 0x7B,// + 0xF0000, /// .
	Left = 0x25,// + 0xF0000, /// .
	Right = 0x27,// + 0xF0000, /// .
	Up = 0x26,// + 0xF0000, /// .
	Down = 0x28,// + 0xF0000, /// .
	Insert = 0x2d,// + 0xF0000, /// .
	Delete = 0x2e,// + 0xF0000, /// .
	Home = 0x24,// + 0xF0000, /// .
	End = 0x23,// + 0xF0000, /// .
	PageUp = 0x21,// + 0xF0000, /// .
	PageDown = 0x22,// + 0xF0000, /// .
}

/* These match simpledisplay.d which match terminal.d, so you can just cast them */

enum MouseEventType : int {
	motion = 0,
	buttonPressed = 1,
	buttonReleased = 2,
}

enum MouseButton : int {
	// these names assume a right-handed mouse
	left = 1,
	right = 2,
	middle = 4,
	wheelUp = 8,
	wheelDown = 16,
}



/*
mixin template ImageSupport() {
	import arsd.png;
	import arsd.bmp;
}
*/


/* helper functions that are generally useful but not necessarily required */

version(use_libssh2) {
	import arsd.libssh2;
	void startChild(alias masterFunc)(string host, short port, string username, string keyFile, string expectedFingerprint = null) {

	int tries = 0;
	try_again:
	try {
		import std.socket;

		if(libssh2_init(0))
			throw new Exception("libssh2_init");
		scope(exit)
			libssh2_exit();

		auto socket = new Socket(AddressFamily.INET, SocketType.STREAM);
		socket.connect(new InternetAddress(host, port));
		scope(exit) socket.close();

		auto session = libssh2_session_init_ex(null, null, null, null);
		if(session is null) throw new Exception("init session");
		scope(exit)
			libssh2_session_disconnect_ex(session, 0, "normal", "EN");

		libssh2_session_flag(session, LIBSSH2_FLAG_COMPRESS, 1);

		if(libssh2_session_handshake(session, socket.handle))
			throw new Exception("handshake");

		auto fingerprint = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA1);
		if(expectedFingerprint !is null && fingerprint[0 .. expectedFingerprint.length] != expectedFingerprint)
			throw new Exception("fingerprint");

		import std.string : toStringz;
		if(auto err = libssh2_userauth_publickey_fromfile_ex(session, username.ptr, username.length, toStringz(keyFile ~ ".pub"), toStringz(keyFile), null))
			throw new Exception("auth");


		auto channel = libssh2_channel_open_ex(session, "session".ptr, "session".length, LIBSSH2_CHANNEL_WINDOW_DEFAULT, LIBSSH2_CHANNEL_PACKET_DEFAULT, null, 0);

		if(channel is null)
			throw new Exception("channel open");

		scope(exit)
			libssh2_channel_free(channel);

		// libssh2_channel_setenv_ex(channel, "ELVISBG".dup.ptr, "ELVISBG".length, "dark".ptr, "dark".length);

		if(libssh2_channel_request_pty_ex(channel, "xterm", "xterm".length, null, 0, 80, 24, 0, 0))
			throw new Exception("pty");

		if(libssh2_channel_process_startup(channel, "shell".ptr, "shell".length, null, 0))
			throw new Exception("process_startup");

		libssh2_keepalive_config(session, 0, 60);
		libssh2_session_set_blocking(session, 0);

		masterFunc(socket, session, channel);
	} catch(Exception e) {
		if(e.msg == "handshake") {
			tries++;
			import core.thread;
			Thread.sleep(200.msecs);
			if(tries < 10)
				goto try_again;
		}

		throw e;
	}
	}

} else
version(Posix) {
	extern(C) static int forkpty(int* master, /*int* slave,*/ void* name, void* termp, void* winp);
	pragma(lib, "util");

	/// this is good
	void startChild(alias masterFunc)(string program, string[] args) {
		import core.sys.posix.termios;
		import core.sys.posix.signal;
		import core.sys.posix.sys.wait;
		__gshared static int childrenAlive = 0;
		extern(C) nothrow static @nogc
		void childdead(int) {
			childrenAlive--;

			wait(null);

			version(with_eventloop)
			try {
				import arsd.eventloop;
				if(childrenAlive <= 0)
					exit();
			} catch(Exception e){}
		}

		signal(SIGCHLD, &childdead);

		int master;
		int pid = forkpty(&master, null, null, null);
		if(pid == -1)
			throw new Exception("forkpty");
		if(pid == 0) {
			import std.process;
			environment["TERM"] = "xterm"; // we're closest to an xterm, so definitely want to pretend to be one to the child processes
			environment["TERM_EXTENSIONS"] = "arsd"; // announce our extensions

			environment["LANG"] = "en_US.UTF-8"; // tell them that utf8 rox (FIXME: what about non-US?)

			import core.sys.posix.unistd;

			import core.stdc.stdlib;
			char** argv = cast(char**) malloc((char*).sizeof * (args.length + 1));
			if(argv is null) throw new Exception("malloc");
			foreach(i, arg; args) {
				argv[i] = cast(char*) malloc(arg.length + 1);
				if(argv[i] is null) throw new Exception("malloc");
				argv[i][0 .. arg.length] = arg[];
				argv[i][arg.length] = 0;
			}

			argv[args.length] = null;

			core.sys.posix.unistd.execv(argv[0], argv);
		} else {
			childrenAlive = 1;
			masterFunc(master);
		}
	}
} else
version(Windows) {
	import core.sys.windows.windows;

	version(winpty) {
		alias HPCON = HANDLE;
		extern(Windows)
			HRESULT ResizePseudoConsole(HPCON, COORD);
		extern(Windows)
			HRESULT CreatePseudoConsole(COORD, HANDLE, HANDLE, DWORD, HPCON*);
		extern(Windows)
			void ClosePseudoConsole(HPCON);
	}

	extern(Windows)
		BOOL PeekNamedPipe(HANDLE, LPVOID, DWORD, LPDWORD, LPDWORD, LPDWORD);
	extern(Windows)
		BOOL GetOverlappedResult(HANDLE,OVERLAPPED*,LPDWORD,BOOL);
	extern(Windows)
		BOOL ReadFileEx(HANDLE, LPVOID, DWORD, OVERLAPPED*, void*);
	extern(Windows)
		BOOL PostMessageA(HWND hWnd,UINT Msg,WPARAM wParam,LPARAM lParam);

	extern(Windows)
		BOOL PostThreadMessageA(DWORD, UINT, WPARAM, LPARAM);
	extern(Windows)
		BOOL RegisterWaitForSingleObject( PHANDLE phNewWaitObject, HANDLE hObject, void* Callback, PVOID Context, ULONG dwMilliseconds, ULONG dwFlags);
	extern(Windows)
		BOOL SetHandleInformation(HANDLE, DWORD, DWORD);
	extern(Windows)
	HANDLE CreateNamedPipeA(
		const(char)* lpName,
		DWORD dwOpenMode,
		DWORD dwPipeMode,
		DWORD nMaxInstances,
		DWORD nOutBufferSize,
		DWORD nInBufferSize,
		DWORD nDefaultTimeOut,
		LPSECURITY_ATTRIBUTES lpSecurityAttributes
	);
	extern(Windows)
	BOOL UnregisterWait(HANDLE);

	__gshared HANDLE waitHandle;
	__gshared bool childDead;
	extern(Windows)
	void childCallback(void* tidp, bool) {
		auto tid = cast(DWORD) tidp;
		UnregisterWait(waitHandle);

		PostThreadMessageA(tid, WM_QUIT, 0, 0);
		childDead = true;
		//stupidThreadAlive = false;
	}



	extern(Windows)
	void SetLastError(DWORD);

	/// this is good. best to call it with plink.exe so it can talk to unix
	/// note that plink asks for the password out of band, so it won't actually work like that.
	/// thus specify the password on the command line or better yet, use a private key file
	/// e.g.
	/// startChild!something("plink.exe", "plink.exe user@server -i key.ppk \"/home/user/terminal-emulator/serverside\"");
	void startChild(alias masterFunc)(string program, string commandLine) {
		import core.sys.windows.windows;
		// thanks for a random person on stack overflow for this function
		static BOOL MyCreatePipeEx(
			PHANDLE lpReadPipe,
			PHANDLE lpWritePipe,
			LPSECURITY_ATTRIBUTES lpPipeAttributes,
			DWORD nSize,
			DWORD dwReadMode,
			DWORD dwWriteMode
		)
		{
			HANDLE ReadPipeHandle, WritePipeHandle;
			DWORD dwError;
			CHAR[MAX_PATH] PipeNameBuffer;

			if (nSize == 0) {
				nSize = 4096;
			}

			static int PipeSerialNumber = 0;

			import core.stdc.string;
			import core.stdc.stdio;

			sprintf(PipeNameBuffer.ptr,
				"\\\\.\\Pipe\\TerminalEmulatorPipe.%08x.%08x".ptr,
				GetCurrentProcessId(),
				PipeSerialNumber++
			);

			ReadPipeHandle = CreateNamedPipeA(
				PipeNameBuffer.ptr,
				1/*PIPE_ACCESS_INBOUND*/ | dwReadMode,
				0/*PIPE_TYPE_BYTE*/ | 0/*PIPE_WAIT*/,
				1,             // Number of pipes
				nSize,         // Out buffer size
				nSize,         // In buffer size
				120 * 1000,    // Timeout in ms
				lpPipeAttributes
			);

			if (! ReadPipeHandle) {
				return FALSE;
			}

			WritePipeHandle = CreateFileA(
				PipeNameBuffer.ptr,
				GENERIC_WRITE,
				0,                         // No sharing
				lpPipeAttributes,
				OPEN_EXISTING,
				FILE_ATTRIBUTE_NORMAL | dwWriteMode,
				null                       // Template file
			);

			if (INVALID_HANDLE_VALUE == WritePipeHandle) {
				dwError = GetLastError();
				CloseHandle( ReadPipeHandle );
				SetLastError(dwError);
				return FALSE;
			}

			*lpReadPipe = ReadPipeHandle;
			*lpWritePipe = WritePipeHandle;
			return( TRUE );
		}





		import std.conv;

		SECURITY_ATTRIBUTES saAttr;
		saAttr.nLength = SECURITY_ATTRIBUTES.sizeof;
		saAttr.bInheritHandle = true;
		saAttr.lpSecurityDescriptor = null;

		HANDLE inreadPipe;
		HANDLE inwritePipe;
		if(CreatePipe(&inreadPipe, &inwritePipe, &saAttr, 0) == 0)
			throw new Exception("CreatePipe");
		if(!SetHandleInformation(inwritePipe, 1/*HANDLE_FLAG_INHERIT*/, 0))
			throw new Exception("SetHandleInformation");
		HANDLE outreadPipe;
		HANDLE outwritePipe;
		if(MyCreatePipeEx(&outreadPipe, &outwritePipe, &saAttr, 0, FILE_FLAG_OVERLAPPED, 0) == 0)
			throw new Exception("CreatePipe");
		if(!SetHandleInformation(outreadPipe, 1/*HANDLE_FLAG_INHERIT*/, 0))
			throw new Exception("SetHandleInformation");

		version(winpty) {
			HPCON hpc;
			auto result = CreatePseudoConsole(
				size,
				inwritePipe,
				outreadPipe,
				0, // flags
				&hpc
			);

			scope(exit)
				ClosePseudoConsole(hpc);
		}

		STARTUPINFOA startupInfo;
		startupInfo.cb = startupInfo.sizeof;

		startupInfo.dwFlags = STARTF_USESTDHANDLES;
		startupInfo.hStdInput = inreadPipe;
		startupInfo.hStdOutput = outwritePipe;
		startupInfo.hStdError = GetStdHandle(STD_ERROR_HANDLE);//outwritePipe;

		PROCESS_INFORMATION pi;
		import std.conv;

		if(commandLine.length > 255)
			throw new Exception("command line too long");
		char[256] cmdLine;
		cmdLine[0 .. commandLine.length] = commandLine[];
		cmdLine[commandLine.length] = 0;
		import std.string;
		if(CreateProcessA(program is null ? null : toStringz(program), cmdLine.ptr, null, null, true, 0/*0x08000000 /* CREATE_NO_WINDOW */, null /* environment */, null, &startupInfo, &pi) == 0)
			throw new Exception("CreateProcess " ~ to!string(GetLastError()));

		if(RegisterWaitForSingleObject(&waitHandle, pi.hProcess, &childCallback, cast(void*) GetCurrentThreadId(), INFINITE, 4 /* WT_EXECUTEINWAITTHREAD */ | 8 /* WT_EXECUTEONLYONCE */) == 0)
			throw new Exception("RegisterWaitForSingleObject");

		version(winpty)
			masterFunc(hpc, inwritePipe, outreadPipe);
		else
			masterFunc(inwritePipe, outreadPipe);

		//stupidThreadAlive = false;

		//term.stupidThread.join();

		/* // FIXME: we should close but only if we're legit done
		// masterFunc typically runs an event loop but it might not.
		CloseHandle(inwritePipe);
		CloseHandle(outreadPipe);

		CloseHandle(pi.hThread);
		CloseHandle(pi.hProcess);
		*/
	}
}

/// Implementation of TerminalEmulator's abstract functions that forward them to output
mixin template ForwardVirtuals(alias writer) {
	static import arsd.color;

	protected override void changeCursorStyle(CursorStyle style) {
		// FIXME: this should probably just import utility
		final switch(style) {
			case TerminalEmulator.CursorStyle.block:
				writer("\033[2 q");
			break;
			case TerminalEmulator.CursorStyle.underline:
				writer("\033[4 q");
			break;
			case TerminalEmulator.CursorStyle.bar:
				writer("\033[6 q");
			break;
		}
	}

	protected override void changeWindowTitle(string t) {
		import std.process;
		if(t.length && environment["TERM"] != "linux")
			writer("\033]0;"~t~"\007");
	}

	protected override void changeWindowIcon(arsd.color.IndexedImage t) {
		if(t !is null) {
			// forward it via our extension. xterm and such seems to ignore this so we should be ok just sending, except to Linux
			import std.process;
			if(environment["TERM"] != "linux")
				writer("\033]5000;" ~ encodeSmallTextImage(t) ~ "\007");
		}
	}

	protected override void changeIconTitle(string) {} // FIXME
	protected override void changeTextAttributes(TextAttributes) {} // FIXME
	protected override void soundBell() {
		writer("\007");
	}
	protected override void demandAttention() {
		import std.process;
		if(environment["TERM"] != "linux")
			writer("\033]5001;1\007"); // the 1 there means true but is currently ignored
	}
	protected override void copyToClipboard(string text) {
		// this is xterm compatible, though xterm rarely implements it
		import std.base64;
				// idk why the cast is needed here
		writer("\033]52;c;"~Base64.encode(cast(ubyte[])text)~"\007");
	}
	protected override void pasteFromClipboard(void delegate(in char[]) dg) {
		// this is a slight extension. xterm invented the string - it means request the primary selection -
		// but it generally doesn't actually get a reply. so i'm using it to request the primary which will be
		// sent as a pasted strong.
		// (xterm prolly doesn't do it by default because it is potentially insecure, letting a naughty app steal your clipboard data, but meh, any X application can do that too and it is useful here for nesting.)
		writer("\033]52;c;?\007");
	}
	protected override void copyToPrimary(string text) {
		import std.base64;
		writer("\033]52;p;"~Base64.encode(cast(ubyte[])text)~"\007");
	}
	protected override void pasteFromPrimary(void delegate(in char[]) dg) {
		writer("\033]52;p;?\007");
	}

}

/// you can pass this as PtySupport's arguments when you just don't care
final void doNothing() {}

/// You must implement a function called redraw() and initialize the members in your constructor
mixin template PtySupport(alias resizeHelper) {
	// Initialize these!

	final void redraw_() {
		if(invalidateAll) {
			if(alternateScreenActive)
				foreach(ref t; alternateScreen)
					t.invalidated = true;
			else
				foreach(ref t; normalScreen)
					t.invalidated = true;
			invalidateAll = false;
		}
		redraw();
		//soundBell();
	}

	version(use_libssh2) {
		import arsd.libssh2;
		LIBSSH2_CHANNEL* sshChannel;
	} else version(Windows) {
		import core.sys.windows.windows;
		HANDLE stdin;
		HANDLE stdout;
	} else version(Posix) {
		int master;
	}

	version(use_libssh2) { }
	else version(Posix) {
		int previousProcess = 0;
		int activeProcess = 0;
		int activeProcessWhenResized = 0;
		bool resizedRecently;

		/*
			so, this isn't perfect, but it is meant to send the resize signal to an existing process
			when it isn't in the front when you resize.

			For example, open vim and resize. Then exit vim. We want bash to be updated.

			But also don't want to do too many spurious signals.

			It doesn't handle the case of bash -> vim -> :sh resize, then vim gets signal but
			the outer bash won't see it. I guess I need some kind of process stack.

			but it is okish.
		*/
		override void outputOccurred() {
			import core.sys.posix.unistd;
			auto pgrp = tcgetpgrp(master);
			if(pgrp != -1) {
				if(pgrp != activeProcess) {
					auto previousProcessAtStartup = previousProcess;

					previousProcess = activeProcess;
					activeProcess = pgrp;

					if(resizedRecently) {
						if(activeProcess != activeProcessWhenResized) {
							resizedRecently = false;

							if(activeProcess == previousProcessAtStartup) {
								//import std.stdio; writeln("informing new process ", activeProcess, " of size ", screenWidth, " x ", screenHeight);

								import core.sys.posix.signal;
								kill(-activeProcess, 28 /* 28 == SIGWINCH*/);
							}
						}
					}
				}
			}


			super.outputOccurred();
		}
		//return std.file.readText("/proc/" ~ to!string(pgrp) ~ "/cmdline");
	}


	override void resizeTerminal(int w, int h) {
		version(Posix) {
			activeProcessWhenResized = activeProcess;
			resizedRecently = true;
		}

		resizeHelper();

		super.resizeTerminal(w, h);

		version(use_libssh2) {
			libssh2_channel_request_pty_size_ex(sshChannel, w, h, 0, 0);
		} else version(Posix) {
			import core.sys.posix.sys.ioctl;
			winsize win;
			win.ws_col = cast(ushort) w;
			win.ws_row = cast(ushort) h;

			ioctl(master, TIOCSWINSZ, &win);
		} else version(Windows) {
			version(winpty) {
				COORD coord;
				coord.x = cast(ushort) w;
				coord.y = cast(ushort) y;
				ResizePseudoConsole(hpc, coord);
			} else {
				sendToApplication([cast(ubyte) 254, cast(ubyte) w, cast(ubyte) h]);
			}
		} else static assert(0);
	}

	protected override void sendToApplication(scope const(void)[] data) {
		version(use_libssh2) {
			while(data.length) {
				auto sent = libssh2_channel_write_ex(sshChannel, 0, data.ptr, data.length);
				if(sent < 0)
					throw new Exception("libssh2_channel_write_ex");
				data = data[sent .. $];
			}
		} else version(Windows) {
			import std.conv;
			uint written;
			if(WriteFile(stdin, data.ptr, cast(uint)data.length, &written, null) == 0)
				throw new Exception("WriteFile " ~ to!string(GetLastError()));
		} else version(Posix) {
			import core.sys.posix.unistd;
			while(data.length) {
				enum MAX_SEND = 1024 * 20;
				auto sent = write(master, data.ptr, data.length > MAX_SEND ? MAX_SEND : cast(int) data.length);
				//import std.stdio; writeln("ROFL ", sent, " ", data.length);

				import core.stdc.errno;
				/*
				if(sent == -1 && errno == 11) {
					import core.thread;
					Thread.sleep(100.msecs);
					//import std.stdio; writeln("lol");
					continue; // just try again
				}
				*/

				import std.conv;
				if(sent < 0)
					throw new Exception("write " ~ to!string(errno));

				data = data[sent .. $];
			}
		} else static assert(0);
	}

	version(use_libssh2) {
		int readyToRead(int fd) {
			int count = 0; // if too much stuff comes at once, we still want to be responsive
			while(true) {
				ubyte[4096] buffer;
				auto got = libssh2_channel_read_ex(sshChannel, 0, buffer.ptr, buffer.length);
				if(got == LIBSSH2_ERROR_EAGAIN)
					break; // got it all for now
				if(got < 0)
					throw new Exception("libssh2_channel_read_ex");
				if(got == 0)
					break; // NOT an error!

				super.sendRawInput(buffer[0 .. got]);
				count++;

				if(count == 5) {
					count = 0;
					redraw_();
					justRead();
				}
			}

			if(libssh2_channel_eof(sshChannel)) {
				libssh2_channel_close(sshChannel);
				libssh2_channel_wait_closed(sshChannel);

				return 1;
			}

			if(count != 0) {
				redraw_();
				justRead();
			}
			return 0;
		}
	} else version(Windows) {
		OVERLAPPED* overlapped;
		bool overlappedBufferLocked;
		ubyte[4096] overlappedBuffer;
		extern(Windows)
		static final void readyToReadWindows(DWORD errorCode, DWORD numberOfBytes, OVERLAPPED* overlapped) {
			assert(overlapped !is null);
			typeof(this) w = cast(typeof(this)) overlapped.hEvent;

			if(numberOfBytes) {
				w.sendRawInput(w.overlappedBuffer[0 .. numberOfBytes]);
				w.redraw_();
			}
			import std.conv;

			if(ReadFileEx(w.stdout, w.overlappedBuffer.ptr, w.overlappedBuffer.length, overlapped, &readyToReadWindows) == 0) {
				if(GetLastError() == 997)
				{ } // there's pending i/o, let's just ignore for now and it should tell us later that it completed
				else
				throw new Exception("ReadFileEx " ~ to!string(GetLastError()));
			} else {
			}

			w.justRead();
		}
	} else version(Posix) {
		void readyToRead(int fd) {
			import core.sys.posix.unistd;
			ubyte[4096] buffer;

			// the count is to limit how long we spend in this loop
			// when it runs out, it goes back to the main event loop
			// for a while (btw use level triggered events so the remaining
			// data continues to get processed!) giving a chance to redraw
			// and process user input periodically during insanely long and
			// rapid output.
			int cnt = 50; // the actual count is arbitrary, it just seems nice in my tests

			version(arsd_te_conservative_draws)
				cnt = 400;

			// FIXME: if connected by ssh, up the count so we don't redraw as frequently.
			// it'd save bandwidth

			while(--cnt) {
				auto len = read(fd, buffer.ptr, 4096);
				if(len < 0) {
					import core.stdc.errno;
					if(errno == EAGAIN || errno == EWOULDBLOCK) {
						break; // we got it all
					} else {
						//import std.conv;
						//throw new Exception("read failed " ~ to!string(errno));
						return;
					}
				}

				if(len == 0) {
					close(fd);
					break;
				}

				auto data = buffer[0 .. len];

				if(debugMode) {
					import std.array; import std.stdio; writeln("GOT ", data, "\nOR ", 
						replace(cast(string) data, "\033", "\\")
						.replace("\010", "^H")
						.replace("\r", "^M")
						.replace("\n", "^J")
						);
				}
				super.sendRawInput(data);
			}

			outputOccurred();

			redraw_();

			// HACK: I don't even know why this works, but with this
			// sleep in place, it gives X events from that socket a
			// chance to be processed. It can add a few seconds to a huge
			// output (like `find /usr`), but meh, that's worth it to me
			// to have a chance to ctrl+c.
			import core.thread;
			Thread.sleep(dur!"msecs"(5));

			justRead();
		}
	}
}

string encodeSmallTextImage(IndexedImage ii) {
	char encodeNumeric(int c) {
		if(c < 10)
			return cast(char)(c + '0');
		if(c < 10 + 26)
			return cast(char)(c - 10 + 'a');
		assert(0);
	}

	string s;
	s ~= encodeNumeric(ii.width);
	s ~= encodeNumeric(ii.height);

	foreach(entry; ii.palette)
		s ~= entry.toRgbaHexString();
	s ~= "Z";

	ubyte rleByte;
	int rleCount;

	void rleCommit() {
		if(rleByte >= 26)
			assert(0); // too many colors for us to handle
		if(rleCount == 0)
			goto finish;
		if(rleCount == 1) {
			s ~= rleByte + 'a';
			goto finish;
		}

		import std.conv;
		s ~= to!string(rleCount);
		s ~= rleByte + 'a';

		finish:
			rleByte = 0;
			rleCount = 0;
	}

	foreach(b; ii.data) {
		if(b == rleByte)
			rleCount++;
		else {
			rleCommit();
			rleByte = b;
			rleCount = 1;
		}
	}

	rleCommit();

	return s;
}

IndexedImage readSmallTextImage(scope const(char)[] arg) {
	auto origArg = arg;
	int width;
	int height;

	int readNumeric(char c) {
		if(c >= '0' && c <= '9')
			return c - '0';
		if(c >= 'a' && c <= 'z')
			return c - 'a' + 10;
		return 0;
	}

	if(arg.length > 2) {
		width = readNumeric(arg[0]);
		height = readNumeric(arg[1]);
		arg = arg[2 .. $];
	}

	import std.conv;
	assert(width == 16, to!string(width));
	assert(height == 16, to!string(width));

	Color[] palette;
	ubyte[256] data;
	int didx = 0;
	bool readingPalette = true;
	outer: while(arg.length) {
		if(readingPalette) {
			if(arg[0] == 'Z') {
				readingPalette = false;
				arg = arg[1 .. $];
				continue;
			}
			if(arg.length < 8)
				break;
			foreach(a; arg[0..8]) {
				// if not strict hex, forget it
				if(!((a >= '0' && a <= '9') || (a >= 'a' && a <= 'z') || (a >= 'A' && a <= 'Z')))
					break outer;
			}
			palette ~= Color.fromString(arg[0 .. 8]);
			arg = arg[8 .. $];
		} else {
			char[3] rleChars;
			int rlePos;
			while(arg.length && arg[0] >= '0' && arg[0] <= '9') {
				rleChars[rlePos] = arg[0];
				arg = arg[1 .. $];
				rlePos++;
				if(rlePos >= rleChars.length)
					break;
			}
			if(arg.length == 0)
				break;

			int rle;
			if(rlePos == 0)
				rle = 1;
			else {
				// 100
				// rleChars[0] == '1'
				foreach(c; rleChars[0 .. rlePos]) {
					rle *= 10;
					rle += c - '0';
				}
			}

			foreach(i; 0 .. rle) {
				if(arg[0] >= 'a' && arg[0] <= 'z')
					data[didx] = cast(ubyte)(arg[0] - 'a');

				didx++;
				if(didx == data.length)
					break outer;
			}

			arg = arg[1 .. $];
		}
	}

	// width, height, palette, data is set up now

	if(palette.length) {
		auto ii = new IndexedImage(width, height);
		ii.palette = palette;
		ii.data = data.dup;

		return ii;
	}// else assert(0, origArg);
	return null;
}


// workaround dmd bug fixed in next release
//static immutable Color[256] xtermPalette = [
immutable(Color)[] xtermPalette() {

	// This is an approximation too for a few entries, but a very close one.
	Color xtermPaletteIndexToColor(int paletteIdx) {
		Color color;
		color.a = 255;

		if(paletteIdx < 16) {
			if(paletteIdx == 7)
				return Color(229, 229, 229); // real is 0xc0 but i think this is easier to see
			else if(paletteIdx == 8)
				return Color(0x80, 0x80, 0x80);

			// real xterm uses 0x88 here, but I prefer 0xcd because it is easier for me to see
			color.r = (paletteIdx & 0b001) ? ((paletteIdx & 0b1000) ? 0xff : 0xcd) : 0x00;
			color.g = (paletteIdx & 0b010) ? ((paletteIdx & 0b1000) ? 0xff : 0xcd) : 0x00;
			color.b = (paletteIdx & 0b100) ? ((paletteIdx & 0b1000) ? 0xff : 0xcd) : 0x00;

		} else if(paletteIdx < 232) {
			// color ramp, 6x6x6 cube
			color.r = cast(ubyte) ((paletteIdx - 16) / 36 * 40 + 55);
			color.g = cast(ubyte) (((paletteIdx - 16) % 36) / 6 * 40 + 55);
			color.b = cast(ubyte) ((paletteIdx - 16) % 6 * 40 + 55);

			if(color.r == 55) color.r = 0;
			if(color.g == 55) color.g = 0;
			if(color.b == 55) color.b = 0;
		} else {
			// greyscale ramp, from 0x8 to 0xee
			color.r = cast(ubyte) (8 + (paletteIdx - 232) * 10);
			color.g = color.r;
			color.b = color.g;
		}

		return color;
	}

	static immutable(Color)[] ret;
	if(ret.length == 256)
		return ret;

	ret.reserve(256);
	foreach(i; 0 .. 256)
		ret ~= xtermPaletteIndexToColor(i);

	return ret;
}

static shared immutable dchar[dchar] lineDrawingCharacterSet;
shared static this() {
	lineDrawingCharacterSet = [
		'a' : ':',
		'j' : '+',
		'k' : '+',
		'l' : '+',
		'm' : '+',
		'n' : '+',
		'q' : '-',
		't' : '+',
		'u' : '+',
		'v' : '+',
		'w' : '+',
		'x' : '|',
	];

	// this is what they SHOULD be but the font i use doesn't support all these
	// the ascii fallback above looks pretty good anyway though.
	version(none)
	lineDrawingCharacterSet = [
		'a' : '\u2592',
		'j' : '\u2518',
		'k' : '\u2510',
		'l' : '\u250c',
		'm' : '\u2514',
		'n' : '\u253c',
		'q' : '\u2500',
		't' : '\u251c',
		'u' : '\u2524',
		'v' : '\u2534',
		'w' : '\u252c',
		'x' : '\u2502',
	];
}

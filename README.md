This is a terminal emulator library and ui with some xterm features and some extensions.

BUILDING

See the example makefile for what I do on my system. You'll need a collection of files from my arsd repo, then just pass them all right over using the same version and -J flags I did.

	dmd main.d terminalemulator.d -L-lutil ~/arsd/{color,eventloop,stb_truetype,xwindows,png,bmp,simpledisplay}.d -version=with_eventloop -J.

for one example


It expects a monospace font to be availble. I use the bitstream vera or the dejavu monospaces and rename them as the monospace-2.ttf.

You can probably just do like

    cp /usr/share/fonts/TTF/DejaVuSansMono.ttf monospace-2.ttf

if you're on Linux or download the font http://web.archive.org/web/20111127102009/http://www-old.gnome.org/fonts/


Or even just modify the code to remove that bit or load it from your system at runtime. Maybe I'll change that later anyway.

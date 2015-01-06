all:
	dmd main.d terminalemulator.d -L-lutil /home/me/arsd/simpledisplay.d /home/me/arsd/color.d /home/me/arsd/eventloop.d -version=with_eventloop -debug -g \
		/home/me/arsd/stb_truetype.d -J/home/me/arsd /home/me/arsd/xwindows.d \
		/home/me/arsd/png.d /home/me/arsd/bmp.d -m64
	#dmd serverside.d -L-lutil
	#dmdw main.d /home/me/arsd/simpledisplay.d /home/me/arsd/color.d -debug /home/me/arsd/stb_truetype.d terminalemulator.d -J/home/me/arsd /home/me/arsd/png.d /home/me/arsd/bmp.d
	dmd nestedterminalemulator.d terminalemulator.d ~/arsd/terminal.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop
	#dmdw nestedterminalemulator.d terminalemulator.d ~/arsd/terminal.d ~/arsd/color.d ~/arsd/simpledisplay.d
	#dmd utility ~/arsd/terminal terminalemulator ~/arsd/color -version=terminalextensions_commandline ~/arsd/png.d
	dmd -m64 attach message.d ~/arsd/terminal detachable.d terminalemulator.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop # utility.d
	dmd -m64 detachable.d terminalemulator.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop message.d ~/arsd/terminal.d -version=standalone_detachable


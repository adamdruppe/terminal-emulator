all:
	#dmd main.d terminalemulator.d -L-lutil /home/me/arsd/simpledisplay.d /home/me/arsd/color.d /home/me/arsd/eventloop.d -version=with_eventloop -debug -g /home/me/arsd/ttf.d -J/home/me/arsd /home/me/arsd/png.d /home/me/arsd/bmp.d -m64 # -version=use_libssh2 ~/arsd/libssh2.d -ofsshmain
	#dmdw main.d /home/me/arsd/simpledisplay.d /home/me/arsd/color.d -debug /home/me/arsd/ttf.d terminalemulator.d -J/home/me/arsd /home/me/arsd/png.d /home/me/arsd/bmp.d -L/SUBSYSTEM:WINDOWS:5.0 -version=use_libssh2 /home/me/arsd/libssh2.d /home/me/arsd/libssh2.lib
	dmd -m64 attach message.d ~/arsd/terminal detachable.d terminalemulator.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop -debug -g utility.d ~/arsd/png.d -version=arsd_te_conservative_draws
	#dmd utility ~/arsd/terminal terminalemulator ~/arsd/color -version=terminalextensions_commandline ~/arsd/png.d
	#dmd nestedterminalemulator.d terminalemulator.d ~/arsd/terminal.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop
	#dmdw nestedterminalemulator.d terminalemulator.d ~/arsd/terminal.d ~/arsd/color.d ~/arsd/simpledisplay.d # -version=use_libssh2 /home/me/arsd/libssh2.d /home/me/arsd/libssh2.lib
	dmd -m64 detachable.d terminalemulator.d ~/arsd/color.d ~/arsd/eventloop.d -version=with_eventloop message.d ~/arsd/terminal.d -version=standalone_detachable -debug -g # this separate detachable is for debugging, this is also available in attach so the separate thing isn't strictly needed


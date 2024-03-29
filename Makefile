# This makefile is designed for use on my computer. You will probably have to adapt the paths for your computer.
#
# just use make -B target instead of thinking about deps....

ARSD=/home/me/arsd

all:

main:
	dmd main.d $(ARSD)/core.d $(ARSD)/terminalemulator.d -L-lutil $(ARSD)/simpledisplay.d $(ARSD)/color.d $(ARSD)/jsvar.d $(ARSD)/script.d $(ARSD)/textlayouter.d $(ARSD)/minigui.d -debug -g $(ARSD)/ttf.d -J$(ARSD) $(ARSD)/png.d $(ARSD)/bmp.d $(ARSD)/jpeg.d $(ARSD)/svg.d -m64 -version=without_opengl # -version=use_libssh2 $(ARSD)/libssh2.d -ofsshmain
mactabs:
	dmd mactabs.d $(ARSD)/core.d $(ARSD)/terminalemulator.d -L-lutil $(ARSD)/simpledisplay.d $(ARSD)/color.d $(ARSD)/jsvar.d $(ARSD)/script.d $(ARSD)/textlayouter.d $(ARSD)/minigui.d -debug -g $(ARSD)/ttf.d -J$(ARSD) $(ARSD)/png.d $(ARSD)/bmp.d $(ARSD)/jpeg.d $(ARSD)/svg.d -m64 # -version=use_libssh2 $(ARSD)/libssh2.d -ofsshmain
main.exe:
	dmdw main.d $(ARSD)/simpledisplay.d $(ARSD)/color.d -debug $(ARSD)/ttf.d $(ARSD)/terminalemulator.d -J$(ARSD) $(ARSD)/png.d $(ARSD)/bmp.d -L/SUBSYSTEM:WINDOWS -m32omf -version=use_libssh2 $(ARSD)/jpeg.d $(ARSD)/svg.d $(ARSD)/libssh2.d $(ARSD)/libssh2.lib $(ARSD)/textlayouter.d $(ARSD)/minigui.d $(ARSD)/jsvar.d $(ARSD)/script.d
winpty.exe:
	dmdw -ofwinpty.exe main.d $(ARSD)/core.d $(ARSD)/simpledisplay.d $(ARSD)/color.d -debug $(ARSD)/ttf.d $(ARSD)/terminalemulator.d -J$(ARSD) $(ARSD)/png.d $(ARSD)/jpeg.d $(ARSD)/svg.d $(ARSD)/bmp.d -m32 -L/SUBSYSTEM:WINDOWS $(ARSD)/textlayouter.d $(ARSD)/minigui.d $(ARSD)/jsvar.d $(ARSD)/script.d -version=winpty -g
attach:
	dmd -m64 attach message.d $(ARSD)/terminal $(ARSD)/core.d detachable.d $(ARSD)/terminalemulator.d $(ARSD)/color.d $(ARSD)/eventloop.d -version=with_eventloop -debug -g utility.d $(ARSD)/png.d $(ARSD)/jpeg.d $(ARSD)/svg.d -version=arsd_te_conservative_draws
detachable:
	dmd -m64 detachable.d $(ARSD)/terminalemulator.d $(ARSD)/core.d $(ARSD)/color.d $(ARSD)/eventloop.d -version=with_eventloop message.d $(ARSD)/terminal.d -version=standalone_detachable -debug -g # this separate detachable is for debugging, this is also available in attach so the separate thing isn't strictly needed
utility:
	dmd utility $(ARSD)/terminal $(ARSD)/terminalemulator $(ARSD)/core.d $(ARSD)/color -version=terminalextensions_commandline $(ARSD)/png.d
nestedterminalemulator:
	dmd nestedterminalemulator.d $(ARSD)/core.d $(ARSD)/terminalemulator.d $(ARSD)/terminal.d $(ARSD)/color.d $(ARSD)/eventloop.d -version=with_eventloop
nestedterminalemulator.exe:
	dmdw nestedterminalemulator.d $(ARSD)/core.d $(ARSD)/terminalemulator.d $(ARSD)/terminal.d $(ARSD)/color.d $(ARSD)/simpledisplay.d # -version=use_libssh2 $(ARSD)/libssh2.d $(ARSD)/libssh2.lib


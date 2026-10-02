rdfeed(1)

# NAME

rdfeed - the RemoteApps of your company in the Linux app menu

# SYNOPSIS

*rdfeed* [_command_]

# DESCRIPTION

Companies publish their Windows apps (Word, Excel, their own tools) as an RD
Web Access feed. Windows subscribes to it under "RemoteApp and Desktop
Connections" and puts the apps in the start menu, in a folder with the name of
the workspace. rdfeed does the same on Linux: each app gets an entry in the
app menu and opens as a window of its own, not as a whole Windows desktop.
The apps run on the company's servers, through FreeRDP.

Run without a command it shows an interactive menu. Everything it can be told
is reachable from there; the files behind it do not need to be edited by
hand.

# COMMANDS

*add* [_address_] [*--user* _name_]
	Add a workspace. The address is the one of the feed, as Windows takes it
	(*https://server/RDWeb/Feed/webfeed.aspx*), or just the server name, or
	the RD Web Access page, or a work e-mail address. For an e-mail address
	the feed is looked up in the TXT record *\_msradc.*_domain_, as Windows
	does it. The user name can be _DOMAIN\\name_, _name@domain_, or just the
	name, which takes the server's own domain.

	Without a terminal, the user name and the password are read from stdin,
	one per line.

*refresh* [_workspace_]
	Load the apps of every workspace again, or of the one given. Apps that
	were added show up in the app menu, apps that were taken away disappear.

*list*
	The workspaces with their apps, each as _workspace/app_, the name *run*
	takes.

*run* _app_ [_file_]
	Start an app. _app_ is enough when only one workspace has an app of that
	name, otherwise _workspace/app_. This is what the app menu entries run.

	With a file, the app opens it. The folder of the file is shared as a
	drive for that session, and the app is started with the path on it,
	_\\\\tsclient\\folder\\file_, the way Windows does it. If the server
	does not let the app take a file this way, it opens empty, and the file
	is on that drive.

*remove* _workspace_
	Remove a workspace: its app menu entries, its folder, the downloaded
	files, the saved password.

*-h*, *--help*
	Show the help.

*-V*, *--version*
	Show the version.

# SETTINGS

*Share a folder*
	Off, Documents, Downloads or the home folder. The apps see it as a drive
	and can open and save files there. Off by default: then they only see the
	files on the server.

*Open files with the apps*
	On by default. The app menu entries name the file types of each app, so
	file managers offer it under "Open with", for example Word for .docx
	files. The types come from the feed when the administrator entered them,
	as Windows takes them. Most feeds have none, and then rdfeed knows the
	usual ones: Word, Excel, PowerPoint, OneNote, Outlook, Visio, Access,
	Project, Publisher, PDF readers, AutoCAD and DWG TrueView, Notepad. Your
	default apps stay as they are.

*Size*
	How big the apps are drawn on the server. Automatic takes the scale your
	desktop gives X11 programs that scale themselves (KDE Plasma's Xwayland
	scale, or Xft.dpi), so the apps come out sharp and the right size.

*Sound*
	Play the sound of the apps on this computer.

*Graphics*
	GFX (the default) or classic. See *FREERDP PROBLEMS*.

*Wait for the second MFA prompt*
	Automatic (the default), always or never. See *FREERDP PROBLEMS*.

*Refresh the apps every day*
	A systemd user timer (*rdfeed-refresh.timer*) that loads the apps again
	once a day, as Windows does. It is switched on with the first workspace.
	When the password stops working it says so in a notification.

# FREERDP PROBLEMS

rdfeed starts each app with *xfreerdp3* (*xfreerdp* on Fedora) in RemoteApp
mode, with *rdfeed-hook.so* loaded into it. The hook works around two
problems that leave FreeRDP hanging or windows half painted:

*The second MFA prompt*
	Most companies run a connection broker, which sends the client on to the
	server that hosts the session. FreeRDP then opens a second tunnel through
	the RD Gateway at once. With MFA on the gateway (the Azure MFA extension
	of NPS), that second sign-in needs a second prompt in the authenticator
	app. When it comes less than about ten seconds after the first one was
	confirmed, no prompt is sent and the gateway waits forever. So the hook
	waits 12 seconds before a new gateway connection, and a notification says
	a second prompt is coming. Automatic waits only when the first sign-in
	took long enough for somebody to confirm a prompt.

*Windows that stay empty*
	In RemoteApp mode with the graphics pipeline (GFX), FreeRDP may not
	repaint a window after it was minimized or resized. FreeRDP 3 has no
	switch to turn GFX off. With *Graphics* on classic, the hook keeps it off
	and every window paints right. But some servers end the session right
	after signing in without GFX, so GFX stays the default. Not fixed yet.

# HOW SAFE IS THIS

The password goes into the keyring (the Secret Service, as GNOME Keyring or
KWallet provide it), never into a file. FreeRDP gets it on stdin, never on its
command line, so it shows in no process list.

The .rdp files from the server can ask to share every drive, camera and USB
device of this computer. rdfeed removes those lines. Only the folder picked
under *Share a folder* is shared, and the folder of a file you open in an app,
for as long as that session runs.

The server's certificate is trusted the first time and checked after that
(*/cert:tofu*). The feed itself is fetched over HTTPS with the system's
certificates.

# FILES

_~/.config/rdfeed/config_
	The settings.

_~/.config/rdfeed/workspaces/_
	One file per workspace: the address, the name, the user.

_~/.local/share/rdfeed/_
	The apps of each workspace: the .rdp files and the icons.

_~/.local/share/applications/rdfeed-\*.desktop_
	The app menu entries, with a folder per workspace in
	_~/.config/menus/applications-merged/_.

_~/.cache/rdfeed/_
	The log of the last start of each app, for when something goes wrong.

# LIMITS

Only feeds that sign in with Windows (NTLM) authentication, which is what RD
Web Access uses. Azure Virtual Desktop and Windows 365 sign in with Microsoft
Entra and are not supported.

Starting a second app of the same workspace opens a second connection, which
takes over the session of the first: its windows move into the new one.
Nothing closes.

# SEE ALSO

*xfreerdp3*(1), *secret-tool*(1)

# AUTHORS

Felitendo. Source and bug reports: https://github.com/LoonixTools/rdfeed

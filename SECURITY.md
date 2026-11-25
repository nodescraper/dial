# Security

If you find a security problem (for example in how the plugin handles tokens, or the apps store credentials), please **do not open a public issue**. Use GitHub's private vulnerability reporting on this repository ("Security" tab, "Report a vulnerability").

A few things worth knowing:

- The apps keep the Jellyfin access token in the system Keychain (iOS) or equivalent; on the Mac a copy is kept in the app's sandbox so you stay signed in across updates.
- The plugin only serves signed-in users; changing settings needs an administrator.
- Never commit a Ticketmaster key, a server address or a token.

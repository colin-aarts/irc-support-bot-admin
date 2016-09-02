
#	irc-support-bot-admin
#	--------------------
#	Administration functionality for irc-support-bot
#	This is an official plug-in
#
#	Provides five bot commands: 'raw', 'set', 'del', 'ignore' and 'reload'

'use strict'


util  = require 'util'
fs    = require 'fs'
js    = require 'js-extensions'



# Load the ignored users datastore
ignored-users = let
	ignored-users = fs.read-file-sync "#{process.cwd!}/ignored-users.json", 'utf-8'
	return JSON.parse ignored-users if ignored-users


# Provide a function for saving the ignored users datastore
save-ignored-users = ->
	fs.write-file "#{process.cwd!}/ignored-users.json", JSON.stringify ignored-users, 'utf-8'



module.exports = ->

	#
	#	Command: raw
	#

	this.register_special_command do
		name: 'raw'
		description: 'Send a raw IRC command'
		admin_only: true
		fn: (event, input-data, output-data) ~> this.irc.raw input-data.args



	#
	#	Command: set
	#

	this.register_special_command do
		name: 'set'
		description: 'Add or update a factoid'
		admin_only: true
		fn: (event, input-data, output-data) ~>

			if '?' in input-data.flags
				message = [
					'''Syntax: set[/r!] <factoid-name> = <factoid-content> • Add or update a factoid'''
					'''--- This command supports the following flags ---'''
					'''r • regexp: enables regexp mode; <factoid-content> must be a sed-style (s///) substitution literal, conforming to JavaScript regular expression syntax'''
					'''a • alias: alias mode; create an alias to an existing factoid: <factoid-content> becomes a factoid name instead'''
					'''! • force: this flag must be set to overwrite an existing factoid when not in regexp mode; otherwise a warning will be issued'''
				]

			else if not args_match = input-data.args.match /^(.+)\s+=\s+(.+)/
				message = '''Sorry, it looks like you're missing some arguments!'''

			else
				factoid-name = args_match[1].trim()
				factoid-exists = factoid-name of this.factoids

				# Alias mode
				if 'a' in input-data.flags

					target-factoid = args_match.2.trim!

					if not (target-factoid of this.factoids)
						message = """Sorry, I couldn't find an existing factoid with the name « #{target-factoid} » to create an alias for"""
					else if factoid-name is target-factoid
						message = """Sorry, I won't let you create a circular reference :)"""
					else if factoid-exists and not ('!' in input-data.flags)
						message = """Sorry, a factoid with the name « #{factoid-name} » already exists. If you want to overwrite this factoid, you must use the '!' flag"""
					else
						if /^alias:/.test this.factoids[target-factoid]
							# target is an alias, so link to the original instead
							target-factoid = this.factoids[target-factoid].replace /^alias:/, ''

						this.factoids[factoid-name] = "alias:#{target-factoid}"
						this.save_factoids()

						message = """I successfully created « #{factoid-name} » as an alias for « #{target-factoid} »"""

				# Regexp mode
				else if 'r' in input-data.flags

					# In regexp mode, we can't create a new factoid, only update existing ones
					if not factoid-exists
						message = """Sorry, but I couldn't find a factoid with the name « #{factoid-name} »"""

					else
						# We're matching a regexp in the form s///, but JS doesn't have look-behind, so we're matching in reverse and using look-ahead instead
						regexp-match = (js.str_reverse args_match[2].trim()).match ///
							^
							(.*?)		# Flags
							(?!/\\)		# NOT /\
							/			# /
							(.*?)		# Replacement
							(?!/\\)		# NOT /\
							/			# /
							(.+?)		# Find pattern
							(?!/\\)		# NOT /\
							/s			# /s
							$
							///

						if not regexp-match
							message = '''Sorry, that's an invalid regexp argument; the expected format is `<factoid-name> = s/<find>/<replace>/<flags>` where <find> is a JavaScript-compatible regular expression'''

						else
							# Undo the reversal
							regexp-match = regexp-match.splice(1).reverse().map (item) -> return js.str_reverse item

							[regexp-find, regexp-replace, regexp-flags] = regexp-match

							regexp-find = regexp-find.replace /// \\/ ///g, '\/'
							regexp-replace = regexp-replace.replace /// \\/ ///g, '\/'
							try regexp = new RegExp regexp-find, regexp-flags

							if not regexp
								message = '''Sorry, the regular expression pattern you provided is invalid'''
							else
								this.factoids[factoid-name] = this.factoids[factoid-name].replace regexp, regexp-replace
								this.save_factoids!

								message = """I successfully updated the factoid « #{factoid-name} » with content « #{this.factoids[factoid-name]} »"""

				# Normal assignment mode
				else
					if factoid-exists and not ('!' in input-data.flags)
						message = """Sorry, a factoid with the name « #{factoid-name} » already exists. If you want to overwrite this factoid, you must use the '!' flag"""

					else
						factoid-content = args_match.2.trim!

						if /^alias:/.test factoid-content
							message = "Sorry, but you can't create factoids of which the content starts with 'alias:'"
						else
							this.factoids[factoid-name] = factoid-content
							this.save_factoids!

							message = """I successfully #{if factoid-exists then 'updated' else 'added'} the factoid « #{factoid-name} »"""

			this.send 'notice', event.person.nick, message



	#
	#	Command: del
	#

	this.register_special_command do
		name: 'del'
		description: 'Delete a factoid'
		admin_only: true
		fn: (event, input-data, output-data) ~>

			if '?' in input-data.flags
				message = [
					'''Syntax: del[/!] <factoid-name> • Delete a factoid'''
					'''--- This command supports the following flags ---'''
					'''! • force: enables deletion of factoids that have aliases leading to it; will also delete all aliases'''
				]

			else if not (input-data.args.trim() of this.factoids)
				message = """Sorry, you can't delete a factoid that doesn't exist!"""

			else
				factoid-name = input-data.args.trim()
				factoid-content = this.factoids[factoid-name]
				is-alias = /^alias:/.test factoid-content
				factoid-original-name = if is-alias then (factoid-content.match /^alias:(.*)/)[1] else factoid-name
				factoid-original-content = this.factoids[factoid-original-name]
				aliases = this.factoid_get_aliases factoid-original-name

				if is-alias
					delete this.factoids[factoid-name]
					this.save_factoids()

					message = """I successfully deleted factoid « #{factoid-name} » which was an alias to « #{factoid-original-name} »"""

				else if not aliases
					delete this.factoids[factoid-name]
					this.save_factoids()

					message = """I successfully deleted factoid « #{factoid-name} » which had the content « #{factoid-content} »"""

				# Else, the factoid is an original, with aliases leading to it.
				else
					if not ('!' in input-data.flags)
						message = """I noticed the factoid you're trying to delete has aliases leading to it (see « #{input-data.trigger}info #{factoid-name} »). If you want to delete this factoid, and all aliases leading to it, you must specify the '!' flag"""

					else
						delete this.factoids[factoid-name]
						for alias in aliases then delete this.factoids[alias]
						this.save_factoids()

						message = """I successfully deleted the factoid « #{factoid-name} » and all aliases leading to it. The deleted factoid's content was « #{factoid-content} »"""

			this.send 'notice', event.person.nick, message



	#
	#	Command: ignore
	#

	this.register_special_command do
		name: 'ignore'
		description: 'Manage the list of ignored users'
		admin_only: true
		fn: (event, input-data, output-data) ~>

			if '?' in input-data.flags
				message = [
					'''Syntax: ignore[/lrc] [<nick> <host>] • Manage the list of ignored users. When no flag is specified, adds an entry (both <nick> and <host> are required; at most one of these may be the value `null` in order to not use it as a constraint).'''
					'''--- This command supports the following flags ---'''
					'''l • list: display a list of ignored users'''
					'''r • remove: remove an entry from the list; must be provided with both <nick> and <host>, as recorded in the list'''
					'''c • clear: clear all entries from the list'''
				]

			# List mode
			else if 'l' in input-data.flags
				message = []
				if ignored-users.length
					message.push "I have the following #{ignored-users.length} users ignored:"
					for entry in ignored-users
						host = if entry.host is null then '(null)' else entry.host
						message.push "nick: #{entry.nick} • host: #{host}"
				else
					message = "I don't currently have anyone on my ignore list"

			# Clear mode
			else if 'c' in input-data.flags
				ignored-users := []
				save-ignored-users!
				message = "I have cleared the list of ignored users"

			# Remove mode
			else if 'r' in input-data.flags
				ignore-match = input-data.args.trim().split ' '

				if ignore-match.length isnt 2
					message = "Sorry, you must provide both <nick> and <host> and they must match the information in the list"

				else
					nick = if ignore-match.0 is 'null' then null else ignore-match.0
					host = if ignore-match.1 is 'null' then null else ignore-match.1
					match_found = false

					for entry, index in ignored-users
						if entry.nick is nick and entry.host is host
							ignored-users.splice index, 1
							save-ignored-users!
							match_found = true
							message = "I have successfully removed the entry from the list of ignored users"
							break

					if not match_found
						message = "Sorry, I couldn't find that entry in the list of ignored users"

			# Add mode
			else
				add-match = input-data.args.trim!.split ' '

				if add-match.length isnt 2
					message = "Sorry, you must provide both <nick> and <host>; at most one of these may be the value `null` in order to not use it as a constraint"

				else
					nick = if add-match.0 is 'null' then null else add-match.0
					host = if add-match.1 is 'null' then null else add-match.1

					if nick is null and host is null
						message = "Sorry, <nick> and <host> cannot both be `null`"

					else
						ignored-users.push { nick: nick, host: host }
						save-ignored-users!
						message = "I successfully added the entry to the list of ignored users"

			this.send 'notice', event.person.nick, message



	#
	#	Command: reload
	#

	this.register_special_command do
		name: 'reload'
		description: '''Reload the bot (it really just kills the bot; if a supervisor is monitoring the process, it'll restart'''
		admin_only: true
		fn: (event, input-data, output-data) ~> throw new Error 'Force reload!'



	#
	#	Callbacks
	#

	this.register_message_callback (event, input-data, output-data) ~>

			# See if the sender is on the ignore list
			is_ignored_user = this.user_match ignored-users, { nick: event.person.nick, host: event.person.host }

			if is_ignored_user
				message = "You're on my ignore list, so don't bother :)"
				this.send 'notice', event.person.nick, message
				return false
			else
				return true


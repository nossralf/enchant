/* enchant: List misspellings in a file.
 *
 * Copyright (C) 2003 Dom Lachowicz
 *               2007 Hannu Väisänen
 *               2016-2024 Reuben Thomas
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along along with this program; if not, see
 * <https://www.gnu.org/licenses/>.
 *
 * In addition, as a special exception, the copyright holders
 * give permission to link the code of this program with
 * the non-LGPL Spelling Provider libraries (eg: a MSFT Office
 * spell checker backend) and distribute linked combinations including
 * the two.  You must obey the GNU Lesser General Public License in all
 * respects for all of the code used other than said providers. If you modify
 * this file, you may extend this exception to your version of the
 * file, but you are not obligated to do so. If you do not wish to
 * do so, delete this exception statement from your version.
 */

using Enchant;

using Posix;

string charset;

string? get_line(FileStream fin) {
	string str = fin.read_line();
	if (str != null && str.length > 0) {
		try {
			return convert(str, str.length, "UTF-8", charset);
		} catch (ConvertError e) {
			/* Assume that str is already utf8 and glib is just being stupid. */
		}
	}
	return str;
}

void print_utf(string str) {
	size_t bytes_written;
	try {
		string native = str.locale_from_utf8(str.length, null, out bytes_written);
		/* Print arbitrary bytes (including potential NULs). */
		unowned uint8[] buf = (uint8[]) native;
		buf.length = (int)bytes_written;
		GLib.stdout.write(buf);
	} catch (GLib.ConvertError e) {
		/* Assume that it's already utf8 and glib is just being stupid. */
		print("%s", str);
	}
}

/* Splits a line into a set of (word,word_position) tuples. */
class Token {
	public string word;
	public long pos;

	public Token(string word, long pos) {
		this.word = word;
		this.pos = pos;
	}
}

SList<Token> tokenize_line(Dict dict, string line) {
	var tokens = new SList<Token>();
	long start_pos = 0;
	long cur_pos = 0;
	unowned string utf = line;

	while (utf[0] != '\0') {
		unichar uc;

		/* Skip non-word characters. */
		for (uc = utf.get_char();
			 uc != 0 && !dict.is_word_character(uc, WordPosition.START);
			 uc = utf.get_char()) {
			utf = utf.next_char();
		}
		start_pos = line.pointer_to_offset(utf);

		/* Skip over word characters. */
		for (;
			 uc != 0 && dict.is_word_character(uc, WordPosition.MIDDLE);
			 uc = utf.get_char()) {
			utf = utf.next_char();
		}

		/* Skip backwards over any characters that can't appear at the end of a word. */
		unowned string i_utf = utf.prev_char();
		for (;
			 !dict.is_word_character(i_utf.get_char(), WordPosition.END);
			 i_utf = i_utf.prev_char());

		/* Save (word, position) tuple. */
		cur_pos = line.pointer_to_offset(i_utf);
		if (cur_pos > start_pos) {
			var word = line.substring(start_pos, cur_pos - start_pos + 1);
			tokens.append(new Token(word, start_pos));
		}
	}

	return tokens;
}

void usage(OptionContext ctx) {
	print("%s", ctx.get_help(false, null));
	exit(1);
}

void describe_dict(string lang_tag,
				   string provider_name,
				   string provider_desc,
				   string provider_file) {
	print("%s (%s)\n", lang_tag, provider_name);
}

void describe_word_chars(string lang_tag,
						 string provider_name,
						 string provider_desc,
						 string provider_file,
						 Dict self) {
	string word_chars = "";
	if (self != null)
		word_chars = self.get_extra_word_characters();
	print("%s\n", word_chars != null ? word_chars : "");
}

void describe_provider(string name, string desc, string file) {
	print("%s (%s)\n", name, desc);
}

string get_user_language() {
	// The returned list always contains "C".
	unowned string[] languages = Intl.get_language_names();
	GLib.assert(languages != null);
	return languages[0];
}

public class Main : Object {
	private static string dictionary = null;
	private static string perslist = null;
	[CCode (array_length = false, array_null_terminated = true)]
	private static string[] files; /* FILE... */
	private static bool version = false;
	private static bool list_misspellings = false;
	private static bool count_lines = false;
	private static bool list_providers = false;
	private static bool list_dictionaries = false;
	private static bool show_default_dict = false;
	private static bool show_word_chars = false;

	private const OptionEntry[] main_options = {
		{"errors-only", 'l', OptionFlags.NONE, OptionArg.NONE, ref list_misspellings, "List misspellings in the input files, or standard input", null},
		{"dictionary", 'd', OptionFlags.NONE, OptionArg.STRING, ref dictionary, "Use the given language", null},
		{"pwl", 'p', OptionFlags.NONE, OptionArg.FILENAME, ref perslist, "Use the given personal word list", null},
		{"show-lines", 'L', OptionFlags.NONE, OptionArg.NONE, ref count_lines, "Display line numbers", null},
		{"list-providers", '\0', OptionFlags.NONE, OptionArg.NONE, ref list_providers, "List spelling providers", null},
		{"list-dicts", '\0', OptionFlags.NONE, OptionArg.NONE, ref list_dictionaries, "List all dictionaries", null},
		{"default-dict", '\0', OptionFlags.NONE, OptionArg.NONE, ref show_default_dict, "Show the default dictionary for the given or default language", null},
		{"word-chars", '\0', OptionFlags.NONE, OptionArg.NONE, ref show_word_chars, "Show the word characters for the given or default language", null},
		{"version", 'v', OptionFlags.NONE, OptionArg.NONE, ref version, "Display version information and exit", null},

		/* Files */
		{OPTION_REMAINING, '\0', OptionFlags.NONE, OptionArg.FILENAME_ARRAY, ref files, null, "FILE…"},
		{null}
	};

	private static bool parse_file(FileStream fin) {
		var broker = new Broker();
		unowned var dict = broker.request_dict_with_pwl(dictionary, perslist);

		if (dict == null) {
			GLib.stderr.printf("No dictionary available for '%s'", dictionary);
			string errmsg = broker.get_error();
			if (errmsg != null)
				GLib.stderr.printf(": %s", errmsg);
			GLib.stderr.putc('\n');

			return false;
		}

		var corrected_something = false;
		size_t line_count = 0;
		string str;
		while ((str = get_line(fin)) != null) {
			if (count_lines)
				line_count++;

			if (str.length > 0) {
				corrected_something = false;

				var tokens = tokenize_line(dict, str);
				if (tokens == null)
					GLib.stdout.putc('\n');
				for (unowned var tok_ptr = tokens; tok_ptr != null; tok_ptr = tok_ptr.next) {
					corrected_something = true;

					var token = tokens.data;
					var word = token.word;
					if (list_misspellings && dict.check(word, word.length) != 0) {
						if (line_count > 0)
							print("%zu ", line_count);
						print_utf(word);
						GLib.stdout.putc('\n');
					}
				}
			}

			GLib.stdout.flush();
		}

		return true;
	}

	public static int main(string[] args) {
		/* Initialize system locale */
		Intl.setlocale();

		get_charset(out charset);
		// FIXME
		// #ifdef _WIN32
		//	/* If reading from stdin, its CP may not be the system CP (which glib's locale gives us) */
		//	if (GetFileType(GetStdHandle(STD_INPUT_HANDLE)) == FILE_TYPE_CHAR)
		//		charset = g_strdup_printf("CP%u", GetConsoleCP());
		// #endif

		var ctx = new OptionContext("\n\nList misspellings in a file.");
		ctx.set_help_enabled(true);
		ctx.add_main_entries(main_options, null);
		try {
			ctx.parse(ref args);
		} catch (OptionError e) {
			printerr("error %s\n", e.message);
			usage(ctx);
		}

		if (version) {
			print("%s\n", PACKAGE_STRING);
			exit(0);
		}

		/* Ensure we have a language set. */
		if (dictionary == null) {
			dictionary = get_user_language();
			if (dictionary == "C")
				dictionary = "en";
		}

		/* Initialise a broker as we will need it now. */
		var broker = new Broker();

		if (list_providers) {
			broker.describe(describe_provider);
			exit(0);
		} else if (list_dictionaries) {
			broker.list_dicts(describe_dict);
			exit(0);
		} else if (show_default_dict || show_word_chars) {
			unowned var dict = broker.request_dict(dictionary);
			if (dict == null) {
				GLib.stderr.printf("No dictionary available for '%s'", dictionary);
				string errmsg = broker.get_error();
				if (errmsg != null)
					GLib.stderr.printf(": %s", errmsg);
				GLib.stderr.putc('\n');
				exit(1);
			} else {
				DictDescribeFn fn;
				if (show_default_dict)
					fn = describe_dict;
				else
					fn = describe_word_chars;
				dict.describe(fn, dict);
				exit(0);
			}
		}

		/* Exit with usage if not checking spelling. */
		if (!list_misspellings)
			usage(ctx);

		/* Process the file or standard input. */
		FileStream fp = null;
		if (files == null)
			return parse_file(GLib.stdin) ? 0 : 1;

		foreach (var f in files) {
			fp = FileStream.open(f, "rb");
			if (fp == null) {
				GLib.stderr.printf("Error: Could not open the file \"%s\" for reading.\n", f);
				exit(1);
			}
			if (!parse_file(fp))
				exit(1);
		}

		return 0;
	}
}

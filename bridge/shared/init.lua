-- Muss vor allem anderen laufen: reicht lib.string.startsWith/endsWith nach, die diese
-- ox_lib-Fassung nicht mitbringt (siehe Datei). Ohne das brechen 34 Aufrufe im Bridge- und
-- Server-Teil ab.
require 'bridge.shared.stringcompat'
-- Loaded for side effects: framework detection runs once and hard-errors when no supported
-- framework is started.
require 'bridge.shared.framework'
-- Loaded for side effects: the locale boot thread loads locales/<config.Locale>.json.
require 'bridge.shared.locale'

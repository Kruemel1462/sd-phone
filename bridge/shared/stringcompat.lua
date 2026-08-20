-- ox_lib liefert lib.string erst ab einer neueren Fassung mit startsWith/endsWith aus. Die hier
-- installierte Fassung (imports/string/shared.lua) setzt lediglich `lib.string = string` und
-- ergaenzt string.random - startsWith gibt es dort nicht. sd-phone ruft es an 33 Stellen auf,
-- endsWith an einer; ohne diese Datei bricht jede davon mit
-- "attempt to call a nil value (field 'startsWith')" ab.
--
-- Bewusst hier statt in ox_lib gepatcht: eine Aenderung dort waere beim naechsten ox_lib-Update
-- wieder verschwunden. lib.string zeigt auf die string-Tabelle DIESER Resource, die Ergaenzung
-- bleibt also auf sd-phone beschraenkt und beeinflusst kein anderes Skript.
--
-- Die Pruefung auf Vorhandensein laesst die Datei wirkungslos werden, sobald ox_lib die
-- Funktionen selbst mitbringt - dann gilt automatisch die Fassung von ox_lib.

local oxstring = lib.string

if not oxstring.startsWith then
    ---Prueft, ob `str` mit `prefix` beginnt.
    ---@param str string
    ---@param prefix string
    ---@return boolean
    function oxstring.startsWith(str, prefix)
        return str:sub(1, #prefix) == prefix
    end
end

if not oxstring.endsWith then
    ---Prueft, ob `str` mit `suffix` endet.
    ---@param str string
    ---@param suffix string
    ---@return boolean
    function oxstring.endsWith(str, suffix)
        -- Sonderfall leeres Suffix: str:sub(-0) liefert den ganzen String, der Vergleich waere
        -- sonst nur fuer den leeren String wahr statt immer.
        if suffix == '' then return true end

        return str:sub(-#suffix) == suffix
    end
end

//----------------------------------------------------------------------------// 
///--------------    Import data for simulator . Do      ---------------------//
//----------------------------------------------------------------------------// 

// Objective:  Import updated data for income and wealth comparator on WID 

//--------------------- INDEX ------------------------------------------------//
// 0. Definitions
// 1. Import PPPs 
// 2. Import currencies + EUR MER exchange rates 
// 3. Import regions 
// 4. Import GDP, NNI for all countries 
// 5.  Import GDP, NNI for all countries 
//     		5.1 Add production taxes 
//     		5.2 Add retained earnings stockrate 
//     		5.3 Add MER exchange rate
//     		5.4 Add PPP
//     		5.5 Rename region codes to full names 
// 6. Export sheets to simulator-config-$time.xlsx
//     		6.1 Export Countries sheet
//     		6.2 Export Currencies sheet
//			6.3 Export stock rate per country for methodology
//----------------------------------------------------------------------------//

// Latest modifications: January 2026 by A. Van Der Ree

// ---------------------------- 0. Definitions ---------------------------------
 
global github "~/Documents/GitHub"
global path "$github/wid-income-wealth-comparator"
global widworld "$github/wid-world"
global output "$path/Output"
global input "$path/Input"


global setup "~/Documents/GitHub/wid-world/stata-do/setup.do"
do "$setup" // to store time and date 

// -----------------  1. Import PPPs of countries  -----------------------------

wid, indicator(xlceup) year($pastyear) clear 

keep country value
rename country iso
rename value eurlcuppp

tempfile ppp
save "`ppp'"


// --------------- 2. Import the list of currencies and their MER --------------

// Currency codes: 
import delimited "$widworld/data-input/currency-codes/symbols.csv", ///
	delimiter("\t") encoding(utf8) clear varnames(1) // updated path 

drop if currency == "(none)"
drop if isocode  == "(none)"

keep currency symbol isocode
rename symbol currency_symbol
rename isocode currency_code
rename currency currency_name

replace currency_symbol = currency_code if strpos(currency_symbol, ".svg")

split currency_symbol, parse(" or ")
drop currency_symbol currency_symbol2
rename currency_symbol1 currency_symbol

collapse (firstnm) currency_symbol currency_name, by(currency_code)

tempfile symbols
save "`symbols'"

// Market Exchange rates (in LCU per EUR to be consistent with PPP)
wid, indicators(xlceux) year($pastyear) clear
rename country iso
rename variable widcode
rename value eurlcumer
keep iso widcode year eurlcumer
tempfile mer_eur
save `mer_eur'

// Obtain local currency_code per country to perform merge with currency symbols
import excel "$input/reference-output-file.xlsx", clear firstrow
keep code currency 
rename code iso
merge 1:m iso using `mer_eur'
keep if widcode == "xlceux999i"
keep iso currency year eurlcumer
rename currency currency_code
merge n:1 currency_code using "`symbols'", nogenerate keep(master match)

tempfile mer
save "`mer'"

// ------------------------ 3. Import regions ----------------------------------

use "$input/import-country-codes-output.dta", clear 

keep iso shortname region1 region2
rename shortname name

tempfile countries
save "`countries'"

// World Regions: 
use "$input/import-region-codes-output.dta", clear 

// adding "PPP" and "MER" suffixes for future merges where the currency unit matters
expand 2
bysort iso : gen copy = _n   
replace iso = iso + "-PPP" if copy==1
replace iso = iso + "-MER" if copy==2

generate region = "World regions"
rename titlename name
keep iso name region

tempfile regions
save "`regions'"

append using `countries'

tempfile countries_regions
save "`countries_regions'" 

//---------------- 4. Import GDP, NNI for all countries ------------------------

wid, indicator(mnninc mgdpro) p(p0p100) clear
rename country iso 	
rename percentile p 
rename variable widcode
drop age pop 
reshape wide value, i(iso year p) j(widcode) string
renvars value*, predrop(5)

keep iso year mnninc999i mgdpro999i 
keep if year >= 1980 

// Calculate coefficient for conversion to factor price
merge n:1 iso using "`countries_regions'", nogenerate keep(match) 

// --------------- 5.1 Add production taxes ------------------------------------
preserve
	wid, indicators(yptxgo ynninc mgdpro mptxgo mhweal) clear
	rename country iso
	keep iso variable year value
	reshape wide value, i(iso year) j(variable) string
	renvars value*, predrop(5)
	
// generate factor price conversion for income comparator
	generate coef_factorprice = 1 - yptxgo999i/ynninc999i
	
// generate factor price conversion for wealth comparator
	gen frac = mptxgo999i / mgdpro999i
	gen frac_hweal = mhweal999i / mgdpro999i
	generate coef_factorprice_hweal = 1 - frac/frac_hweal
	
	tempfile factorprice
	save `factorprice'
restore

merge 1:1 iso year using `factorprice'
drop _merge

// complete for missing years 
sort iso year
by iso: carryforward coef_factorprice, replace

egen frac_mean = mean(coef_factorprice), by(region2 year)
replace coef_factorprice = frac_mean if missing(coef_factorprice)
drop frac_mean

sort iso year
by iso: carryforward coef_factorprice_hweal, replace

egen frac_mean = mean(coef_factorprice_hweal), by(region2 year)
replace coef_factorprice_hweal = frac_mean if missing(coef_factorprice_hweal)
drop frac_mean

// --------------- 5.2 Add rate of returned earnings ---------------------------

// Import retained earnings data 
// estimate a rate of retained earnings by stock
// 		- use cwdeq : market value of corporations (equity liability)
// 		- use prico : net primary income of corporations (numerator)

preserve
	wid, indicators(mcwdeq mprico) ages(999) clear
	drop age pop percentile
	rename country iso
	reshape wide value, i(iso year) j(variable) string
	renvars value*, predrop(5)

	gen rate = mprico999i / mcwdeq999i
 
	keep iso year rate
	drop if iso == ""

	tempfile stockrate
	save `stockrate'
restore

merge m:1 iso year using `stockrate', nogenerate 

sort iso year
by iso: carryforward rate, replace

egen rate_mean = mean(rate), by(region1 year)
replace rate = rate_mean if missing(rate)
drop rate_mean

egen rate_mean = mean(rate), by(year)
replace rate = rate_mean if missing(rate)
drop rate_mean

// --------------------------- 5.3 Add exchange rate ---------------------------
merge m:1 iso year using "`mer'", nogenerate keep(master match) 

*sort iso year
*by iso: carryforward eurlcumer, replace

keep if year == $pastyear

//----- 6.4 Estimate coefficient for conversion to factor price by world region
generate nni_eur = mnninc999i/eurlcumer

// ------------------------ 5.4 Add PPP ----------------------------------------
merge m:1 iso using "`ppp'", keep(master match) nogenerate

// -------------------- 5.5 Rename regions as full name ------------------------

gen str20 region_en = ""
replace region_en = "Europe" if region1=="QE"
replace region_en = "East Asia" if region1=="QL"
replace region_en = "North America and Oceania" if region1=="XB"
replace region_en = "Sub-Saharan Africa" if region1=="XF"
replace region_en = "Latin America" if region1=="XL"
replace region_en = "Middle East and North Africa" if region1=="XN"
replace region_en = "Russia and Central Asia" if region1=="XR"
replace region_en = "South and Southeast Asia" if region1=="XS"
replace region_en = region if region=="World regions"
drop if region_en==""

generate str20 region_fr = ""
replace region_fr = "Europe" if region1=="QE"
replace region_fr = "Asie de l'Est" if region1=="QL"
replace region_fr = "Amérique du Nord et Océanie" if region1=="XB"
replace region_fr = "Afrique Subsaharienne" if region1=="XF"
replace region_fr = "Amérique Latine" if region1=="XL"
replace region_fr = "Moyen Orient et Afrique du Nord" if region1=="XN"
replace region_fr = "Russie et Asie Centrale" if region1=="XR"
replace region_fr = "Asie du Sud et Sud-Est" if region1=="XS"
replace region_fr ="Régions du monde" if region_en == "World regions"

drop region
gen region = region_en

// -------------------- 5.6 Add french country names ------------------------

rename iso code
gen name_en = name

preserve
	import excel "$input/reference-output-file.xlsx", clear firstrow
	keep code name_fr
	tempfile french
	save `french'
restore

merge 1:1 code using `french'
// dropping small countries we no longer export
drop if _merge == 2	

// fixing french country names for special cases
replace name_fr = "Kosovo" if code=="KS"

replace name_fr = "Autre Russie et Asie Centrale" if strpos(code, "OA-")
replace name_fr = "Autre Asie de l'Est" if strpos(code, "OB-")
replace name_fr = "Autre Europe de l'Ouest" if strpos(code, "OC-")
replace name_fr = "Autre Amérique Latine" if strpos(code, "OD-")
replace name_fr = "Autre MENA" if strpos(code, "OE-")
replace name_fr = "Autre Amérique du Nord et Océanie" if strpos(code, "OH-")
replace name_fr = "Autre Asie du Sud et Sud-Est" if strpos(code, "OI-")
replace name_fr = "Autre Afrique Subsaharienne" if strpos(code, "OJ-")
replace name_fr = "Autre Amérique du Nord" if strpos(code, "OK-")
replace name_fr = "Autre Océanie" if strpos(code, "OL-")

replace name_fr = "Europe" if strpos(code, "QE-")
replace name_fr = "Océanie" if strpos(code, "QF-")
replace name_fr = "Asie de l'Est" if strpos(code, "QL-")
replace name_fr = "Europe de l'Est" if strpos(code, "QM-")
replace name_fr = "Amérique du Nord" if strpos(code, "QP-")
replace name_fr = "Monde" if strpos(code, "WO-")
replace name_fr = "Amérique du Nord et Océanie" if strpos(code, "XB-")
replace name_fr = "Afrique Subsaharienne" if strpos(code, "XF-")
replace name_fr = "Amérique Latine" if strpos(code, "XL-")
replace name_fr = "MENA" if strpos(code, "XN-")
replace name_fr = "Russie et Asie Centrale" if strpos(code, "XR-")
replace name_fr = "Asie du Sud et Sud-Est" if strpos(code, "XS-")

// --------------------------- 6. Export sheets --------------------------------

// clean up
rename rate stockrate
replace stockrate = 0 if code=="AR" // argentina had a negative stockrate

// create binary variable if the country has income and wealth series (now all countries have)
gen str10 enable_country = "TRUE"
gen str10 enable_country_hweal = "TRUE"

replace currency_name = "US dollar" if currency_code == "USD"
replace currency_code = "VEF" if currency_code == "VES"


// call googlesheet that is used for backend to obtain correct format for currencies in french, plural etc
preserve
	import excel "$input/config-2025.xlsx", sheet("Currencies") firstrow clear
	keep code currency_name currency_nameplural currency_name_fr currency_nameplural_fr currency_name_en currency_nameplural_en
	rename code currency_code
	drop if currency_code == ""
	tempfile extracolumns
	save `extracolumns'
restore
merge m:1 currency_code using `extracolumns', gen(merge_currency)

// ordering 
keep code year name region coef_factorprice stockrate currency_code eurlcuppp name_fr region_fr name_en region_en enable_country enable_country_hweal coef_factorprice_hweal eurlcumer currency_name currency_nameplural currency_symbol currency_name_fr currency_nameplural_fr currency_name_en currency_nameplural_en merge_currency 

order code year name region coef_factorprice stockrate currency_code eurlcuppp name_fr region_fr name_en region_en enable_country enable_country_hweal coef_factorprice_hweal eurlcumer currency_name currency_nameplural currency_symbol currency_name_fr currency_nameplural_fr currency_name_en currency_nameplural_en merge_currency

// --------------------------- 7.1 Export Countries sheet ----------------------
preserve
	keep code name region coef_factorprice stockrate currency_code eurlcuppp name_fr region_fr name_en region_en enable_country enable_country_hweal coef_factorprice_hweal
	drop if code==""
	rename currency_code currency

	replace eurlcuppp = 1 if missing(eurlcuppp)
	sort region code
	
	export excel "$output/comparator-config-$time.xlsx", ///
	sheetreplace sheet("Countries") firstrow(variables)
restore

// --------------------------- 7.2 Export Currencies sheet ----------------------
preserve
	gen eurlcu = eurlcumer 
	keep currency_code eurlcu currency_name currency_nameplural currency_symbol currency_name_fr currency_nameplural_fr currency_name_en currency_nameplural_en merge_currency eurlcumer eurlcuppp
	
	order currency_code eurlcu currency_name currency_nameplural currency_symbol currency_name_fr currency_nameplural_fr currency_name_en currency_nameplural_en merge_currency eurlcumer eurlcuppp

	keep if merge_currency == 3
	drop merge_currency
	
	rename currency_code code
	rename currency_symbol symbol

	drop if currency_name == ""
	collapse (firstnm) eurlcu currency_name currency_nameplural symbol currency_name_fr currency_nameplural_fr currency_name_en currency_nameplural_en eurlcumer eurlcuppp, by(code)

	export excel "$output/comparator-config-$time.xlsx", ///
	sheetreplace sheet("Currencies") firstrow(variables)
restore


// ---------------------------- 7.3 Export only stock rate ---------------------
*This is just in case we want to update the methodology table for retained earnings 

preserve
	keep name stockrate
	replace stockrate = stockrate*100
	sort stockrate
	export excel "$output/stockrate-by-country.xlsx", firstrow(variables) replace
restore









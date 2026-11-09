#include <cstdio>
#include <cstring>
#include <memory>
#include <unicode/datefmt.h>
#include <unicode/dtptngen.h>
#include <unicode/gregocal.h>
#include <unicode/measfmt.h>
#include <unicode/measunit.h>
#include <unicode/measure.h>
#include <unicode/smpdtfmt.h>
#include <unicode/timezone.h>
#include <unicode/unistr.h>
using namespace icu;
extern "C" int32_t fastra_macro_datetime(double millis, int32_t format,
                                         int32_t time, const char *locale,
                                         const uint16_t *zone, int32_t zone_len,
                                         uint16_t *out, int32_t capacity,
                                         int32_t *raw_status) {
  UErrorCode status = U_ZERO_ERROR;
  try {
    Locale loc(locale);
    UnicodeString zone_id(reinterpret_cast<const UChar *>(zone), zone_len);
    std::unique_ptr<TimeZone> tz(zone_len ? TimeZone::createTimeZone(zone_id)
                                          : TimeZone::createDefault());
    GregorianCalendar calendar(*tz, Locale::getUS(), status);
    calendar.setTime(millis, status);
    UnicodeString pattern, result;
    std::unique_ptr<DateFormat> formatter;
    if (time) {
      int h = calendar.get(UCAL_HOUR_OF_DAY, status),
          m = calendar.get(UCAL_MINUTE, status),
          s = calendar.get(UCAL_SECOND, status);
      if (format == 3 || format == 4) {
        MeasureFormat measured(loc, UMEASFMT_WIDTH_WIDE, status);
        Measure values[] = {
            Measure(Formattable(h), MeasureUnit::createHour(status), status),
            Measure(Formattable(m), MeasureUnit::createMinute(status), status),
            Measure(Formattable(s), MeasureUnit::createSecond(status), status)};
        FieldPosition field(0);
        measured.formatMeasures(values, format == 3 ? 3 : 2, result, field,
                                status);
        // Darwin verwendet bei genau zwei deutschen Zeiteinheiten die
        // Konjunktion.
        if (format == 4 && std::strcmp(loc.getLanguage(), "de") == 0)
          result.findAndReplace(u", ", u" und ");
      } else if (format == 6) {
        char text[64];
        std::snprintf(text, sizeof(text), "%d:%02d", h * 60 + m, s);
        result = UnicodeString::fromUTF8(text);
      } else
        pattern = (format == 2   ? u"HH:mm"
                   : format == 5 ? u"h:mm a"
                                 : u"HH:mm:ss");
    } else
      switch (format) {
      case 0:
      case 1:
        formatter.reset(
            DateFormat::createDateInstance(DateFormat::kShort, loc));
        break;
      case 2: {
        std::unique_ptr<DateTimePatternGenerator> gen(
            DateTimePatternGenerator::createInstance(loc, status));
        if (U_FAILURE(status) || !gen) {
          *raw_status = U_FAILURE(status) ? status : U_MEMORY_ALLOCATION_ERROR;
          return 0;
        }
        pattern = gen->getBestPattern(u"EEE MMM d yyyy", status);
        // Mit den echten Foundation-Goldens belegt: kein Komma nach dem
        // deutschen Wochentag.
        if (std::strcmp(loc.getLanguage(), "de") == 0) {
          pattern.findAndReplace(u"EEE,", u"EEE");
        }
        break;
      }
      case 3:
        formatter.reset(DateFormat::createDateInstance(DateFormat::kFull, loc));
        break;
      case 4: {
        int y = calendar.get(UCAL_YEAR, status);
        pattern = (y >= 1930 && y <= 2029) ? u"MM/dd/yy" : u"MM/dd/yyyy";
        loc = Locale("en_US_POSIX");
        break;
      }
      case 5:
        pattern = u"MMMM d, yyyy";
        loc = Locale("en_US_POSIX");
        break;
      case 6:
        pattern = u"MMM d, yyyy";
        loc = Locale("en_US_POSIX");
        break;
      case 7:
        pattern = u"MM/dd/yyyy";
        loc = Locale("en_US_POSIX");
        break;
      case 8:
        pattern = u"yyyy-MM-dd'T'00:00:00";
        loc = Locale("en_US_POSIX");
        break;
      default:
        *raw_status = U_ILLEGAL_ARGUMENT_ERROR;
        return 0;
      }
    if (!pattern.isEmpty())
      formatter.reset(new SimpleDateFormat(pattern, loc, status));
    if (formatter) {
      formatter->setTimeZone(*tz);
      formatter->format(millis, result);
    }
    int32_t length =
        result.extract(reinterpret_cast<UChar *>(out), capacity, status);
    *raw_status = status;
    return length;
  } catch (...) {
    *raw_status = U_MEMORY_ALLOCATION_ERROR;
    return 0;
  }
}

# Render a template

`render.sh` fills `${FIELD_NAME}` placeholders in a text template with fields you provide. It writes a uniquely named text file to `OUTPUT_FOLDER` and prints its path.

```bash
OUTPUT_FILE=$(./render.sh email.tmpl \
  OUTPUT_FOLDER="/path/to/output_staging" \
  CONTACT_NAME="Ada Lovelace" \
  DESTINATION="Rome" \
  DAYS="5" \
  HOTEL="Example Hotel" \
  COST="\$2,000" \
  DESTINATION_FAMOUS_FOR="history and cuisine" \
  TOURISM_HIGHLIGHTS="the Colosseum; Vatican Museums; Trevi Fountain" \
  ACTIVITIES_AVAILABLE="pizza-making and food tours")
```

The travel template expects `CONTACT_NAME`, `DESTINATION`, `DAYS`, `HOTEL`, `COST`, `DESTINATION_FAMOUS_FOR`, `TOURISM_HIGHLIGHTS`, and `ACTIVITIES_AVAILABLE`.

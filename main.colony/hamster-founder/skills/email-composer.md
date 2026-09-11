Use the render tool in the configured tools folder at `render/render.sh` with the template at `render/email.tmpl`.

Extract the customer name, destination, number of days, hotel, and cost from the input. Use the destination highlights and activity matching skills to prepare the remaining fields.

Call `render.sh` with `OUTPUT_FOLDER` set to the output destination from the Hamster task prompt and these fields:

- `CONTACT_NAME`
- `DESTINATION`
- `DAYS`
- `HOTEL`
- `COST`
- `DESTINATION_FAMOUS_FOR`
- `TOURISM_HIGHLIGHTS`
- `ACTIVITIES_AVAILABLE`

Let the tool create the output filename. Read the generated file, proofread it, and return only the final email. Do not invent missing details.

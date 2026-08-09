import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const files = process.argv.slice(2);

for (const path of files) {
  const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(path));
  const summary = await workbook.inspect({
    kind: "workbook,sheet,table",
    maxChars: 12000,
    tableMaxRows: 8,
    tableMaxCols: 20,
    tableMaxCellChars: 160,
  });
  console.log(JSON.stringify({ path, summary: summary.ndjson }));
}

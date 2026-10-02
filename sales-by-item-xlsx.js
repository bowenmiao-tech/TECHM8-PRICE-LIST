(function () {
  'use strict';
  const encoder = new TextEncoder();
  const xml = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[char])).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
  const u16 = value => [value & 255, value >>> 8 & 255];
  const u32 = value => [value & 255, value >>> 8 & 255, value >>> 16 & 255, value >>> 24 & 255];
  const crc32 = bytes => {
    let crc = -1;
    for (const byte of bytes) {
      crc ^= byte;
      for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    return (crc ^ -1) >>> 0;
  };
  const column = index => {
    let result = '';
    for (let value = index + 1; value > 0; value = Math.floor((value - 1) / 26)) result = String.fromCharCode(65 + (value - 1) % 26) + result;
    return result;
  };
  function zip(files) {
    const chunks = [], directory = [];
    let offset = 0;
    for (const [path, content] of files) {
      const name = encoder.encode(path), data = encoder.encode(content), crc = crc32(data);
      const local = new Uint8Array([80,75,3,4,20,0,0,8,0,0,0,0,0,0,...u32(crc),...u32(data.length),...u32(data.length),...u16(name.length),0,0]);
      chunks.push(local,name,data);
      directory.push({name,crc,size:data.length,offset});
      offset += local.length + name.length + data.length;
    }
    const directoryStart = offset;
    for (const file of directory) {
      const header = new Uint8Array([80,75,1,2,20,0,20,0,0,8,0,0,0,0,0,0,...u32(file.crc),...u32(file.size),...u32(file.size),...u16(file.name.length),0,0,0,0,0,0,0,0,0,0,0,0,...u32(file.offset)]);
      chunks.push(header,file.name);
      offset += header.length + file.name.length;
    }
    chunks.push(new Uint8Array([80,75,5,6,0,0,0,0,...u16(directory.length),...u16(directory.length),...u32(offset-directoryStart),...u32(directoryStart),0,0]));
    return new Blob(chunks,{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
  }
  function createWorkbook(rows) {
    const sheetRows = rows.map((cells, rowIndex) => `<row r="${rowIndex+1}">${cells.map((cell, columnIndex) => {
      const reference = `${column(columnIndex)}${rowIndex+1}`;
      return typeof cell === 'number' && Number.isFinite(cell)
        ? `<c r="${reference}"${rowIndex ? ' s="2"' : ''}><v>${cell}</v></c>`
        : `<c r="${reference}"${rowIndex ? '' : ' s="1"'} t="inlineStr"><is><t>${xml(cell)}</t></is></c>`;
    }).join('')}</row>`).join('');
    const files = [
      ['[Content_Types].xml','<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'],
      ['_rels/.rels','<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'],
      ['xl/workbook.xml','<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sales By Item" sheetId="1" r:id="rId1"/></sheets></workbook>'],
      ['xl/_rels/workbook.xml.rels','<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'],
      ['xl/styles.xml','<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><sz val="11"/><name val="Arial"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0"/><xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'],
      ['xl/worksheets/sheet1.xml',`<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="6" width="18" customWidth="1"/><col min="7" max="7" width="52" customWidth="1"/><col min="8" max="12" width="16" customWidth="1"/></cols><sheetData>${sheetRows}</sheetData><autoFilter ref="A1:L${rows.length}"/></worksheet>`]
    ];
    return zip(files);
  }
  window.Techm8SalesByItemXlsx = { createWorkbook };
})();

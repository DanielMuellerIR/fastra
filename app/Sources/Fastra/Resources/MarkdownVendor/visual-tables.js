/* Tabellenwerkzeuge verwenden den nativen Undo-Schritt des visuellen Editors. */
(() => {
  'use strict';
  window.fastraCreateTableEditor = ({root, range, blocked, revision, apply, report, fail}) => {
    const identities=new WeakMap();let nextID=0;
    let inspectedCell=null;
    const maxRows=1000,maxColumns=100,maxCells=10000,maxBytes=1048576;
    const element=n=>n?.nodeType===1?n:n?.parentElement;
    function locate() {
      const selected=range();
      if(!selected && !inspectedCell?.isConnected)return null;
      const cell=inspectedCell?.isConnected?inspectedCell:element(selected?.startContainer)?.closest('td,th');
      const table=cell?.closest('table');
      if(!table || !root.contains(table))return null;
      const rows=Array.from(table.rows),row=rows.indexOf(cell.parentElement),column=cell.cellIndex;
      let reason='';
      if(blocked())reason='busy';
      else if(!table.matches('[data-md-table="gfm"]') || table.closest('[data-md-opaque]') || table.querySelector('[colspan],[rowspan],table'))reason='html';
      else if(element(selected.endContainer)?.closest('td,th')!==cell)reason='selection';
      else if(!rows.length || !rows[0].cells.length || rows.some(r=>r.cells.length!==rows[0].cells.length)
              || !Array.from(rows[0].cells).every(c=>c.tagName==='TH') || row<0)reason='html';
      if(!identities.has(table))identities.set(table,String(++nextID));
      const columns=rows[0]?.cells.length || 0;
      return {table,cell,rows,row,column,columns,reason,token:identities.get(table)+':'+revision()+':'+row+':'+column};
    }
    function context() {
      const found=locate();
      if(!found)return null;
      const {row,column,rows,columns,reason,token,cell}=found;
      return {row,column,rows:rows.length,columns,reason,token,alignment:cell.getAttribute('align') || 'default'};
    }
    function focus(cell,select=true) {
      const r=document.createRange();r.selectNodeContents(cell);if(!select)r.collapse(true);
      root.focus();getSelection().removeAllRanges();getSelection().addRange(r);
      cell.scrollIntoView({block:'nearest',inline:'nearest'});report();
    }
    const fits=(rows,columns)=>rows<=maxRows && columns<=maxColumns && rows*columns<=maxCells;
    function emptyCell(tag,alignment) {
      const cell=document.createElement(tag);if(alignment)cell.setAttribute('align',alignment);
      cell.append(document.createElement('br'));return cell;
    }
    function command(name,value='',token=null) {
      const found=locate();
      if(!found)return {ok:false,reason:'selection'};
      if(found.reason)return {ok:false,reason:found.reason};
      if(token!==null && token!==found.token)return {ok:false,reason:'stale'};
      const {table,row,column,rows,columns}=found;
      let targetRow=row,targetColumn=column,fields=null;
      if(name==='pasteCell' && (value.length>maxBytes || new TextEncoder().encode(value).length>maxBytes))return {ok:false,reason:'size'};
      if(name==='pasteTSV') {
        if(value.length>maxBytes || new TextEncoder().encode(value).length>maxBytes)return {ok:false,reason:'size'};
        fields=value.replace(/\r\n?/g,'\n').split('\n');
        if(fields.length>1 && fields.at(-1)==='')fields.pop();
        if(fields.length>maxRows)return {ok:false,reason:'size'};
        fields=fields.map(line=>line.split('\t'));
        if(!fits(fields.length,Math.max(...fields.map(r=>r.length))) || !fits(Math.max(rows.length,row+fields.length),Math.max(columns,column+Math.max(...fields.map(r=>r.length)))))return {ok:false,reason:'size'};
      }
      if(['rowBefore','rowAfter'].includes(name) && !fits(rows.length+1,columns))return {ok:false,reason:'size'};
      if(['columnBefore','columnAfter'].includes(name) && !fits(rows.length,columns+1))return {ok:false,reason:'size'};
      if((['deleteRow','rowBefore'].includes(name) && row===0) || (name==='deleteColumn' && columns===1)
         || (name==='rowUp' && row<=1) || (name==='rowDown' && (row===0 || row===rows.length-1))
         || (name==='columnLeft' && column===0) || (name==='columnRight' && column===columns-1))return {ok:false,reason:'edge'};
      const allowed=['rowBefore','rowAfter','deleteRow','rowUp','rowDown','columnBefore','columnAfter','deleteColumn','columnLeft','columnRight','alignDefault','alignLeft','alignCenter','alignRight','pasteTSV','pasteCell'];
      if(!allowed.includes(name))return {ok:false,reason:'command'};
      const changed=apply(table,clone=>{
        let copiedRows=Array.from(clone.rows);
        const alignment=i=>copiedRows[0].cells[i]?.getAttribute('align');
        function appendRow(index) {
          const r=document.createElement('tr');
          for(let i=0;i<copiedRows[0].cells.length;i++)r.append(emptyCell('td',alignment(i)));
          const previous=copiedRows[index-1];previous.after(r);
          if(r.parentElement.tagName==='THEAD'){
            const body=clone.tBodies[0] || clone.appendChild(document.createElement('tbody'));body.prepend(r);
          }
          copiedRows=Array.from(clone.rows);return r;
        }
        switch(name) {
          case 'rowBefore':case 'rowAfter': {
            const index=Math.max(1,row+(name==='rowAfter'?1:0));
            appendRow(index);
            targetRow=index;break;
          }
          case 'deleteRow':copiedRows[row].remove();targetRow=Math.min(row,rows.length-2);break;
          case 'rowUp':copiedRows[row-1].before(copiedRows[row]);targetRow--;break;
          case 'rowDown':copiedRows[row+1].after(copiedRows[row]);targetRow++;break;
          case 'columnBefore':case 'columnAfter': {
            const index=column+(name==='columnAfter'?1:0),align=alignment(column);
            copiedRows.forEach((r,i)=>r.insertBefore(emptyCell(i===0?'th':'td',align),r.cells[index] || null));targetColumn=index;break;
          }
          case 'deleteColumn':copiedRows.forEach(r=>r.cells[column].remove());targetColumn=Math.min(column,columns-2);break;
          case 'columnLeft':copiedRows.forEach(r=>r.cells[column-1].before(r.cells[column]));targetColumn--;break;
          case 'columnRight':copiedRows.forEach(r=>r.cells[column+1].after(r.cells[column]));targetColumn++;break;
          case 'alignDefault':case 'alignLeft':case 'alignCenter':case 'alignRight': {
            const align=name.slice(5).toLowerCase();copiedRows.forEach(r=>{if(align==='default')r.cells[column].removeAttribute('align');else r.cells[column].setAttribute('align',align);});break;
          }
          case 'pasteCell':copiedRows[row].cells[column].innerHTML=value;break;
          case 'pasteTSV': {
            const width=Math.max(columns,column+Math.max(...fields.map(r=>r.length)));
            copiedRows.forEach((r,i)=>{while(r.cells.length<width)r.append(emptyCell(i===0?'th':'td'));});
            while(copiedRows.length<row+fields.length)appendRow(copiedRows.length);
            fields.forEach((values,y)=>values.forEach((text,x)=>{const cell=copiedRows[row+y].cells[column+x];cell.textContent=text;if(!text)cell.append(document.createElement('br'));}));
            targetRow=row+fields.length-1;targetColumn=column+fields.at(-1).length-1;break;
          }
        }
        return {row:targetRow,column:targetColumn};
      });
      report();return {ok:!!changed,reason:changed?'':'stale'};
    }
    function navigate(backwards) {
      const found=locate();if(!found)return false;
      // Auch geschützte HTML-Tabellen bleiben per Tab ohne Umbau verlassbar.
      if(found.reason)return false;
      let index=found.row*found.columns+found.column+(backwards?-1:1);
      if(index<0){const r=document.createRange();r.setStartBefore(found.table);r.collapse(true);root.focus();getSelection().removeAllRanges();getSelection().addRange(r);report();return true;}
      if(index>=found.rows.length*found.columns){const result=command('rowAfter');if(!result.ok){report();fail(result.reason);return true;}const next=locate();if(next)focus(next.rows[next.row].cells[0]);return true;}
      focus(found.rows[Math.floor(index/found.columns)].cells[index%found.columns]);return true;
    }
    function inspect(cell) {
      const table=cell?.closest('table');
      const next=table && (!table.matches('[data-md-table="gfm"]') || table.closest('[data-md-opaque]'))?cell:null;
      if(inspectedCell===next)return;
      inspectedCell=next;
      report();
    }
    return {context,command,navigate,focus,inspect};
  };
})();

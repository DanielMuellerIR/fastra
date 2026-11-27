/* Fastras lokale WYSIWYG-Schicht auf ProseMirror-Basis (MIT). Originalquellen bleiben im geschlossenen Editorzustand. */
(() => {
  // node_modules/orderedmap/dist/index.js
  function OrderedMap(content) {
    this.content = content;
  }
  OrderedMap.prototype = {
    constructor: OrderedMap,
    find: function(key) {
      for (var i = 0; i < this.content.length; i += 2)
        if (this.content[i] === key) return i;
      return -1;
    },
    // :: (string) → ?any
    // Retrieve the value stored under `key`, or return undefined when
    // no such key exists.
    get: function(key) {
      var found2 = this.find(key);
      return found2 == -1 ? void 0 : this.content[found2 + 1];
    },
    // :: (string, any, ?string) → OrderedMap
    // Create a new map by replacing the value of `key` with a new
    // value, or adding a binding to the end of the map. If `newKey` is
    // given, the key of the binding will be replaced with that key.
    update: function(key, value, newKey) {
      var self = newKey && newKey != key ? this.remove(newKey) : this;
      var found2 = self.find(key), content = self.content.slice();
      if (found2 == -1) {
        content.push(newKey || key, value);
      } else {
        content[found2 + 1] = value;
        if (newKey) content[found2] = newKey;
      }
      return new OrderedMap(content);
    },
    // :: (string) → OrderedMap
    // Return a map with the given key removed, if it existed.
    remove: function(key) {
      var found2 = this.find(key);
      if (found2 == -1) return this;
      var content = this.content.slice();
      content.splice(found2, 2);
      return new OrderedMap(content);
    },
    // :: (string, any) → OrderedMap
    // Add a new key to the start of the map.
    addToStart: function(key, value) {
      return new OrderedMap([key, value].concat(this.remove(key).content));
    },
    // :: (string, any) → OrderedMap
    // Add a new key to the end of the map.
    addToEnd: function(key, value) {
      var content = this.remove(key).content.slice();
      content.push(key, value);
      return new OrderedMap(content);
    },
    // :: (string, string, any) → OrderedMap
    // Add a key after the given key. If `place` is not found, the new
    // key is added to the end.
    addBefore: function(place, key, value) {
      var without = this.remove(key), content = without.content.slice();
      var found2 = without.find(place);
      content.splice(found2 == -1 ? content.length : found2, 0, key, value);
      return new OrderedMap(content);
    },
    // :: ((key: string, value: any))
    // Call the given function for each key/value pair in the map, in
    // order.
    forEach: function(f) {
      for (var i = 0; i < this.content.length; i += 2)
        f(this.content[i], this.content[i + 1]);
    },
    // :: (union<Object, OrderedMap>) → OrderedMap
    // Create a new map by prepending the keys in this map that don't
    // appear in `map` before the keys in `map`.
    prepend: function(map2) {
      map2 = OrderedMap.from(map2);
      if (!map2.size) return this;
      return new OrderedMap(map2.content.concat(this.subtract(map2).content));
    },
    // :: (union<Object, OrderedMap>) → OrderedMap
    // Create a new map by appending the keys in this map that don't
    // appear in `map` after the keys in `map`.
    append: function(map2) {
      map2 = OrderedMap.from(map2);
      if (!map2.size) return this;
      return new OrderedMap(this.subtract(map2).content.concat(map2.content));
    },
    // :: (union<Object, OrderedMap>) → OrderedMap
    // Create a map containing all the keys in this map that don't
    // appear in `map`.
    subtract: function(map2) {
      var result = this;
      map2 = OrderedMap.from(map2);
      for (var i = 0; i < map2.content.length; i += 2)
        result = result.remove(map2.content[i]);
      return result;
    },
    // :: () → Object
    // Turn ordered map into a plain object.
    toObject: function() {
      var result = {};
      this.forEach(function(key, value) {
        result[key] = value;
      });
      return result;
    },
    // :: number
    // The amount of keys in this map.
    get size() {
      return this.content.length >> 1;
    }
  };
  OrderedMap.from = function(value) {
    if (value instanceof OrderedMap) return value;
    var content = [];
    if (value) for (var prop in value) content.push(prop, value[prop]);
    return new OrderedMap(content);
  };
  var dist_default = OrderedMap;

  // node_modules/prosemirror-model/dist/index.js
  function findDiffStart(a, b, pos) {
    for (let i = 0; ; i++) {
      if (i == a.childCount || i == b.childCount)
        return a.childCount == b.childCount ? null : pos;
      let childA = a.child(i), childB = b.child(i);
      if (childA == childB) {
        pos += childA.nodeSize;
        continue;
      }
      if (!childA.sameMarkup(childB))
        return pos;
      if (childA.isText && childA.text != childB.text) {
        let tA = childA.text, tB = childB.text, j = 0;
        for (; tA[j] == tB[j]; j++)
          pos++;
        if (j && j < tA.length && j < tB.length && surrogateHigh(tA.charCodeAt(j - 1)) && surrogateLow(tA.charCodeAt(j)))
          pos--;
        return pos;
      }
      if (childA.content.size || childB.content.size) {
        let inner = findDiffStart(childA.content, childB.content, pos + 1);
        if (inner != null)
          return inner;
      }
      pos += childA.nodeSize;
    }
  }
  function findDiffEnd(a, b, posA, posB) {
    for (let iA = a.childCount, iB = b.childCount; ; ) {
      if (iA == 0 || iB == 0)
        return iA == iB ? null : { a: posA, b: posB };
      let childA = a.child(--iA), childB = b.child(--iB), size = childA.nodeSize;
      if (childA == childB) {
        posA -= size;
        posB -= size;
        continue;
      }
      if (!childA.sameMarkup(childB))
        return { a: posA, b: posB };
      if (childA.isText && childA.text != childB.text) {
        let tA = childA.text, tB = childB.text, iA2 = tA.length, iB2 = tB.length;
        while (iA2 > 0 && iB2 > 0 && tA[iA2 - 1] == tB[iB2 - 1]) {
          iA2--;
          iB2--;
          posA--;
          posB--;
        }
        if (iA2 && iB2 && iA2 < tA.length && surrogateHigh(tA.charCodeAt(iA2 - 1)) && surrogateLow(tA.charCodeAt(iA2))) {
          posA++;
          posB++;
        }
        return { a: posA, b: posB };
      }
      if (childA.content.size || childB.content.size) {
        let inner = findDiffEnd(childA.content, childB.content, posA - 1, posB - 1);
        if (inner)
          return inner;
      }
      posA -= size;
      posB -= size;
    }
  }
  function surrogateLow(ch) {
    return ch >= 56320 && ch < 57344;
  }
  function surrogateHigh(ch) {
    return ch >= 55296 && ch < 56320;
  }
  var Fragment = class _Fragment {
    /**
    @internal
    */
    constructor(content, size) {
      this.content = content;
      this.size = size || 0;
      if (size == null)
        for (let i = 0; i < content.length; i++)
          this.size += content[i].nodeSize;
    }
    /**
    Invoke a callback for all descendant nodes between the given two
    positions (relative to start of this fragment). Doesn't descend
    into a node when the callback returns `false`.
    */
    nodesBetween(from2, to, f, nodeStart = 0, parent) {
      for (let i = 0, pos = 0; pos < to; i++) {
        let child = this.content[i], end = pos + child.nodeSize;
        if (end > from2 && f(child, nodeStart + pos, parent || null, i) !== false && child.content.size) {
          let start = pos + 1;
          child.nodesBetween(Math.max(0, from2 - start), Math.min(child.content.size, to - start), f, nodeStart + start);
        }
        pos = end;
      }
    }
    /**
    Call the given callback for every descendant node. `pos` will be
    relative to the start of the fragment. The callback may return
    `false` to prevent traversal of a given node's children.
    */
    descendants(f) {
      this.nodesBetween(0, this.size, f);
    }
    /**
    Extract the text between `from` and `to`. See the same method on
    [`Node`](https://prosemirror.net/docs/ref/#model.Node.textBetween).
    */
    textBetween(from2, to, blockSeparator, leafText) {
      let text = "", first = true;
      this.nodesBetween(from2, to, (node, pos) => {
        let nodeText = node.isText ? node.text.slice(Math.max(from2, pos) - pos, to - pos) : !node.isLeaf ? "" : leafText ? typeof leafText === "function" ? leafText(node) : leafText : node.type.spec.leafText ? node.type.spec.leafText(node) : "";
        if (node.isBlock && (node.isLeaf && nodeText || node.isTextblock) && blockSeparator) {
          if (first)
            first = false;
          else
            text += blockSeparator;
        }
        text += nodeText;
      }, 0);
      return text;
    }
    /**
    Create a new fragment containing the combined content of this
    fragment and the other.
    */
    append(other) {
      if (!other.size)
        return this;
      if (!this.size)
        return other;
      let last = this.lastChild, first = other.firstChild, content = this.content.slice(), i = 0;
      if (last.isText && last.sameMarkup(first)) {
        content[content.length - 1] = last.withText(last.text + first.text);
        i = 1;
      }
      for (; i < other.content.length; i++)
        content.push(other.content[i]);
      return new _Fragment(content, this.size + other.size);
    }
    /**
    Cut out the sub-fragment between the two given positions.
    */
    cut(from2, to = this.size) {
      if (from2 == 0 && to == this.size)
        return this;
      let result = [], size = 0;
      if (to > from2)
        for (let i = 0, pos = 0; pos < to; i++) {
          let child = this.content[i], end = pos + child.nodeSize;
          if (end > from2) {
            if (pos < from2 || end > to) {
              if (child.isText)
                child = child.cut(Math.max(0, from2 - pos), Math.min(child.text.length, to - pos));
              else
                child = child.cut(Math.max(0, from2 - pos - 1), Math.min(child.content.size, to - pos - 1));
            }
            result.push(child);
            size += child.nodeSize;
          }
          pos = end;
        }
      return new _Fragment(result, size);
    }
    /**
    @internal
    */
    cutByIndex(from2, to) {
      if (from2 == to)
        return _Fragment.empty;
      if (from2 == 0 && to == this.content.length)
        return this;
      return new _Fragment(this.content.slice(from2, to));
    }
    /**
    Create a new fragment in which the node at the given index is
    replaced by the given node.
    */
    replaceChild(index, node) {
      let current = this.content[index];
      if (current == node)
        return this;
      let copy2 = this.content.slice();
      let size = this.size + node.nodeSize - current.nodeSize;
      copy2[index] = node;
      return new _Fragment(copy2, size);
    }
    /**
    Create a new fragment by prepending the given node to this
    fragment.
    */
    addToStart(node) {
      return new _Fragment([node].concat(this.content), this.size + node.nodeSize);
    }
    /**
    Create a new fragment by appending the given node to this
    fragment.
    */
    addToEnd(node) {
      return new _Fragment(this.content.concat(node), this.size + node.nodeSize);
    }
    /**
    Compare this fragment to another one.
    */
    eq(other) {
      if (this.content.length != other.content.length)
        return false;
      for (let i = 0; i < this.content.length; i++)
        if (!this.content[i].eq(other.content[i]))
          return false;
      return true;
    }
    /**
    The first child of the fragment, or `null` if it is empty.
    */
    get firstChild() {
      return this.content.length ? this.content[0] : null;
    }
    /**
    The last child of the fragment, or `null` if it is empty.
    */
    get lastChild() {
      return this.content.length ? this.content[this.content.length - 1] : null;
    }
    /**
    The number of child nodes in this fragment.
    */
    get childCount() {
      return this.content.length;
    }
    /**
    Get the child node at the given index. Raise an error when the
    index is out of range.
    */
    child(index) {
      let found2 = this.content[index];
      if (!found2)
        throw new RangeError("Index " + index + " out of range for " + this);
      return found2;
    }
    /**
    Get the child node at the given index, if it exists.
    */
    maybeChild(index) {
      return this.content[index] || null;
    }
    /**
    Call `f` for every child node, passing the node, its offset
    into this parent node, and its index.
    */
    forEach(f) {
      for (let i = 0, p = 0; i < this.content.length; i++) {
        let child = this.content[i];
        f(child, p, i);
        p += child.nodeSize;
      }
    }
    /**
    Find the first position at which this fragment and another
    fragment differ, or `null` if they are the same.
    */
    findDiffStart(other, pos = 0) {
      return findDiffStart(this, other, pos);
    }
    /**
    Find the first position, searching from the end, at which this
    fragment and the given fragment differ, or `null` if they are
    the same. Since this position will not be the same in both
    nodes, an object with two separate positions is returned.
    */
    findDiffEnd(other, pos = this.size, otherPos = other.size) {
      return findDiffEnd(this, other, pos, otherPos);
    }
    /**
    Find the index and inner offset corresponding to a given relative
    position in this fragment. The result object will be reused
    (overwritten) the next time the function is called. @internal
    */
    findIndex(pos) {
      if (pos == 0)
        return retIndex(0, pos);
      if (pos == this.size)
        return retIndex(this.content.length, pos);
      if (pos > this.size || pos < 0)
        throw new RangeError(`Position ${pos} outside of fragment (${this})`);
      for (let i = 0, curPos = 0; ; i++) {
        let cur = this.child(i), end = curPos + cur.nodeSize;
        if (end >= pos) {
          if (end == pos)
            return retIndex(i + 1, end);
          return retIndex(i, curPos);
        }
        curPos = end;
      }
    }
    /**
    Return a debugging string that describes this fragment.
    */
    toString() {
      return "<" + this.toStringInner() + ">";
    }
    /**
    @internal
    */
    toStringInner() {
      return this.content.join(", ");
    }
    /**
    Create a JSON-serializeable representation of this fragment.
    */
    toJSON() {
      return this.content.length ? this.content.map((n) => n.toJSON()) : null;
    }
    /**
    Deserialize a fragment from its JSON representation.
    */
    static fromJSON(schema2, value) {
      if (!value)
        return _Fragment.empty;
      if (!Array.isArray(value))
        throw new RangeError("Invalid input for Fragment.fromJSON");
      return _Fragment.fromArray(value.map(schema2.nodeFromJSON));
    }
    /**
    Build a fragment from an array of nodes. Ensures that adjacent
    text nodes with the same marks are joined together.
    */
    static fromArray(array) {
      if (!array.length)
        return _Fragment.empty;
      let joined, size = 0;
      for (let i = 0; i < array.length; i++) {
        let node = array[i];
        size += node.nodeSize;
        if (i && node.isText && array[i - 1].sameMarkup(node)) {
          if (!joined)
            joined = array.slice(0, i);
          joined[joined.length - 1] = node.withText(joined[joined.length - 1].text + node.text);
        } else if (joined) {
          joined.push(node);
        }
      }
      return new _Fragment(joined || array, size);
    }
    /**
    Create a fragment from something that can be interpreted as a
    set of nodes. For `null`, it returns the empty fragment. For a
    fragment, the fragment itself. For a node or array of nodes, a
    fragment containing those nodes.
    */
    static from(nodes2) {
      if (!nodes2)
        return _Fragment.empty;
      if (nodes2 instanceof _Fragment)
        return nodes2;
      if (Array.isArray(nodes2))
        return this.fromArray(nodes2);
      if (nodes2.attrs)
        return new _Fragment([nodes2], nodes2.nodeSize);
      throw new RangeError("Can not convert " + nodes2 + " to a Fragment" + (nodes2.nodesBetween ? " (looks like multiple versions of prosemirror-model were loaded)" : ""));
    }
  };
  Fragment.empty = new Fragment([], 0);
  var found = { index: 0, offset: 0 };
  function retIndex(index, offset) {
    found.index = index;
    found.offset = offset;
    return found;
  }
  function compareDeep(a, b) {
    if (a === b)
      return true;
    if (!(a && typeof a == "object") || !(b && typeof b == "object"))
      return false;
    let array = Array.isArray(a);
    if (Array.isArray(b) != array)
      return false;
    if (array) {
      if (a.length != b.length)
        return false;
      for (let i = 0; i < a.length; i++)
        if (!compareDeep(a[i], b[i]))
          return false;
    } else {
      for (let p in a)
        if (!(p in b) || !compareDeep(a[p], b[p]))
          return false;
      for (let p in b)
        if (!(p in a))
          return false;
    }
    return true;
  }
  var Mark = class _Mark {
    /**
    @internal
    */
    constructor(type, attrs) {
      this.type = type;
      this.attrs = attrs;
    }
    /**
    Given a set of marks, create a new set which contains this one as
    well, in the right position. If this mark is already in the set,
    the set itself is returned. If any marks that are set to be
    [exclusive](https://prosemirror.net/docs/ref/#model.MarkSpec.excludes) with this mark are present,
    those are replaced by this one.
    */
    addToSet(set) {
      let copy2, placed = false;
      for (let i = 0; i < set.length; i++) {
        let other = set[i];
        if (this.eq(other))
          return set;
        if (this.type.excludes(other.type)) {
          if (!copy2)
            copy2 = set.slice(0, i);
        } else if (other.type.excludes(this.type)) {
          return set;
        } else {
          if (!placed && other.type.rank > this.type.rank) {
            if (!copy2)
              copy2 = set.slice(0, i);
            copy2.push(this);
            placed = true;
          }
          if (copy2)
            copy2.push(other);
        }
      }
      if (!copy2)
        copy2 = set.slice();
      if (!placed)
        copy2.push(this);
      return copy2;
    }
    /**
    Remove this mark from the given set, returning a new set. If this
    mark is not in the set, the set itself is returned.
    */
    removeFromSet(set) {
      for (let i = 0; i < set.length; i++)
        if (this.eq(set[i]))
          return set.slice(0, i).concat(set.slice(i + 1));
      return set;
    }
    /**
    Test whether this mark is in the given set of marks.
    */
    isInSet(set) {
      for (let i = 0; i < set.length; i++)
        if (this.eq(set[i]))
          return true;
      return false;
    }
    /**
    Test whether this mark has the same type and attributes as
    another mark.
    */
    eq(other) {
      return this == other || this.type == other.type && compareDeep(this.attrs, other.attrs);
    }
    /**
    Convert this mark to a JSON-serializeable representation.
    */
    toJSON() {
      let obj = { type: this.type.name };
      for (let _ in this.attrs) {
        obj.attrs = this.attrs;
        break;
      }
      return obj;
    }
    /**
    Deserialize a mark from JSON.
    */
    static fromJSON(schema2, json) {
      if (!json)
        throw new RangeError("Invalid input for Mark.fromJSON");
      let type = schema2.marks[json.type];
      if (!type)
        throw new RangeError(`There is no mark type ${json.type} in this schema`);
      let mark = type.create(json.attrs);
      return mark;
    }
    /**
    Test whether two sets of marks are identical.
    */
    static sameSet(a, b) {
      if (a == b)
        return true;
      if (a.length != b.length)
        return false;
      for (let i = 0; i < a.length; i++)
        if (!a[i].eq(b[i]))
          return false;
      return true;
    }
    /**
    Create a properly sorted mark set from null, a single mark, or an
    unsorted array of marks.
    */
    static setFrom(marks2) {
      if (!marks2 || Array.isArray(marks2) && marks2.length == 0)
        return _Mark.none;
      if (marks2 instanceof _Mark)
        return [marks2];
      let copy2 = marks2.slice();
      copy2.sort((a, b) => a.type.rank - b.type.rank);
      return copy2;
    }
  };
  Mark.none = [];
  var ReplaceError = class extends Error {
  };
  var Slice = class _Slice {
    /**
    Create a slice. When specifying a non-zero open depth, you must
    make sure that there are nodes of at least that depth at the
    appropriate side of the fragment—i.e. if the fragment is an
    empty paragraph node, `openStart` and `openEnd` can't be greater
    than 1.
    
    It is not necessary for the content of open nodes to conform to
    the schema's content constraints, though it should be a valid
    start/end/middle for such a node, depending on which sides are
    open.
    */
    constructor(content, openStart, openEnd) {
      this.content = content;
      this.openStart = openStart;
      this.openEnd = openEnd;
    }
    /**
    The size this slice would add when inserted into a document.
    */
    get size() {
      return this.content.size - this.openStart - this.openEnd;
    }
    /**
    @internal
    */
    insertAt(pos, fragment) {
      let content = insertInto(this.content, pos + this.openStart, fragment, this.openStart + 1, this.openEnd + 1);
      return content && new _Slice(content, this.openStart, this.openEnd);
    }
    /**
    @internal
    */
    removeBetween(from2, to) {
      return new _Slice(removeRange(this.content, from2 + this.openStart, to + this.openStart), this.openStart, this.openEnd);
    }
    /**
    Tests whether this slice is equal to another slice.
    */
    eq(other) {
      return this.content.eq(other.content) && this.openStart == other.openStart && this.openEnd == other.openEnd;
    }
    /**
    @internal
    */
    toString() {
      return this.content + "(" + this.openStart + "," + this.openEnd + ")";
    }
    /**
    Convert a slice to a JSON-serializable representation.
    */
    toJSON() {
      if (!this.content.size)
        return null;
      let json = { content: this.content.toJSON() };
      if (this.openStart > 0)
        json.openStart = this.openStart;
      if (this.openEnd > 0)
        json.openEnd = this.openEnd;
      return json;
    }
    /**
    Deserialize a slice from its JSON representation.
    */
    static fromJSON(schema2, json) {
      if (!json)
        return _Slice.empty;
      let openStart = json.openStart || 0, openEnd = json.openEnd || 0;
      if (typeof openStart != "number" || typeof openEnd != "number")
        throw new RangeError("Invalid input for Slice.fromJSON");
      return new _Slice(Fragment.fromJSON(schema2, json.content), openStart, openEnd);
    }
    /**
    Create a slice from a fragment by taking the maximum possible
    open value on both side of the fragment.
    */
    static maxOpen(fragment, openIsolating = true) {
      let openStart = 0, openEnd = 0;
      for (let n = fragment.firstChild; n && !n.isLeaf && (openIsolating || !n.type.spec.isolating); n = n.firstChild)
        openStart++;
      for (let n = fragment.lastChild; n && !n.isLeaf && (openIsolating || !n.type.spec.isolating); n = n.lastChild)
        openEnd++;
      return new _Slice(fragment, openStart, openEnd);
    }
  };
  Slice.empty = new Slice(Fragment.empty, 0, 0);
  function removeRange(content, from2, to) {
    let { index, offset } = content.findIndex(from2), child = content.maybeChild(index);
    let { index: indexTo, offset: offsetTo } = content.findIndex(to);
    if (offset == from2 || child.isText) {
      if (offsetTo != to && !content.child(indexTo).isText)
        throw new RangeError("Removing non-flat range");
      return content.cut(0, from2).append(content.cut(to));
    }
    if (index != indexTo)
      throw new RangeError("Removing non-flat range");
    return content.replaceChild(index, child.copy(removeRange(child.content, from2 - offset - 1, to - offset - 1)));
  }
  function insertInto(content, dist, insert, openStart, openEnd, parent) {
    let { index, offset } = content.findIndex(dist), child = content.maybeChild(index);
    if (offset == dist || child.isText) {
      if (parent && openStart <= 0 && openEnd <= 0 && !parent.canReplace(index, index, insert))
        return null;
      return content.cut(0, dist).append(insert).append(content.cut(dist));
    }
    let inner = insertInto(child.content, dist - offset - 1, insert, index == 0 ? openStart - 1 : 0, index == content.childCount - 1 ? openEnd - 1 : 0, child);
    return inner && content.replaceChild(index, child.copy(inner));
  }
  function replace($from, $to, slice2) {
    if (slice2.openStart > $from.depth)
      throw new ReplaceError("Inserted content deeper than insertion position");
    if ($from.depth - slice2.openStart != $to.depth - slice2.openEnd)
      throw new ReplaceError("Inconsistent open depths");
    return replaceOuter($from, $to, slice2, 0);
  }
  function replaceOuter($from, $to, slice2, depth) {
    let index = $from.index(depth), node = $from.node(depth);
    if (index == $to.index(depth) && depth < $from.depth - slice2.openStart) {
      let inner = replaceOuter($from, $to, slice2, depth + 1);
      return node.copy(node.content.replaceChild(index, inner));
    } else if (!slice2.content.size) {
      return close(node, replaceTwoWay($from, $to, depth));
    } else if (!slice2.openStart && !slice2.openEnd && $from.depth == depth && $to.depth == depth) {
      let parent = $from.parent, content = parent.content;
      return close(parent, content.cut(0, $from.parentOffset).append(slice2.content).append(content.cut($to.parentOffset)));
    } else {
      let { start, end } = prepareSliceForReplace(slice2, $from);
      return close(node, replaceThreeWay($from, start, end, $to, depth));
    }
  }
  function checkJoin(main, sub) {
    if (!sub.type.compatibleContent(main.type))
      throw new ReplaceError("Cannot join " + sub.type.name + " onto " + main.type.name);
  }
  function joinable($before, $after, depth) {
    let node = $before.node(depth);
    checkJoin(node, $after.node(depth));
    return node;
  }
  function addNode(child, target) {
    let last = target.length - 1;
    if (last >= 0 && child.isText && child.sameMarkup(target[last]))
      target[last] = child.withText(target[last].text + child.text);
    else
      target.push(child);
  }
  function addRange($start, $end, depth, target) {
    let node = ($end || $start).node(depth);
    let startIndex = 0, endIndex = $end ? $end.index(depth) : node.childCount;
    if ($start) {
      startIndex = $start.index(depth);
      if ($start.depth > depth) {
        startIndex++;
      } else if ($start.textOffset) {
        addNode($start.nodeAfter, target);
        startIndex++;
      }
    }
    for (let i = startIndex; i < endIndex; i++)
      addNode(node.child(i), target);
    if ($end && $end.depth == depth && $end.textOffset)
      addNode($end.nodeBefore, target);
  }
  function close(node, content) {
    if (!node.type.validContent(content))
      throw new ReplaceError("Invalid content for node " + node.type.name);
    return node.copy(content);
  }
  function replaceThreeWay($from, $start, $end, $to, depth) {
    let openStart = $from.depth > depth && joinable($from, $start, depth + 1);
    let openEnd = $to.depth > depth && joinable($end, $to, depth + 1);
    let content = [];
    addRange(null, $from, depth, content);
    if (openStart && openEnd && $start.index(depth) == $end.index(depth)) {
      checkJoin(openStart, openEnd);
      addNode(close(openStart, replaceThreeWay($from, $start, $end, $to, depth + 1)), content);
    } else {
      if (openStart)
        addNode(close(openStart, replaceTwoWay($from, $start, depth + 1)), content);
      addRange($start, $end, depth, content);
      if (openEnd)
        addNode(close(openEnd, replaceTwoWay($end, $to, depth + 1)), content);
    }
    addRange($to, null, depth, content);
    return new Fragment(content);
  }
  function replaceTwoWay($from, $to, depth) {
    let content = [];
    addRange(null, $from, depth, content);
    if ($from.depth > depth) {
      let type = joinable($from, $to, depth + 1);
      addNode(close(type, replaceTwoWay($from, $to, depth + 1)), content);
    }
    addRange($to, null, depth, content);
    return new Fragment(content);
  }
  function prepareSliceForReplace(slice2, $along) {
    let extra = $along.depth - slice2.openStart, parent = $along.node(extra);
    let node = parent.copy(slice2.content);
    for (let i = extra - 1; i >= 0; i--)
      node = $along.node(i).copy(Fragment.from(node));
    return {
      start: node.resolveNoCache(slice2.openStart + extra),
      end: node.resolveNoCache(node.content.size - slice2.openEnd - extra)
    };
  }
  var ResolvedPos = class _ResolvedPos {
    /**
    @internal
    */
    constructor(pos, path, parentOffset) {
      this.pos = pos;
      this.path = path;
      this.parentOffset = parentOffset;
      this.depth = path.length / 3 - 1;
    }
    /**
    @internal
    */
    resolveDepth(val) {
      if (val == null)
        return this.depth;
      if (val < 0)
        return this.depth + val;
      return val;
    }
    /**
    The parent node that the position points into. Note that even if
    a position points into a text node, that node is not considered
    the parent—text nodes are ‘flat’ in this model, and have no content.
    */
    get parent() {
      return this.node(this.depth);
    }
    /**
    The root node in which the position was resolved.
    */
    get doc() {
      return this.node(0);
    }
    /**
    The ancestor node at the given level. `p.node(p.depth)` is the
    same as `p.parent`.
    */
    node(depth) {
      return this.path[this.resolveDepth(depth) * 3];
    }
    /**
    The index into the ancestor at the given level. If this points
    at the 3rd node in the 2nd paragraph on the top level, for
    example, `p.index(0)` is 1 and `p.index(1)` is 2.
    */
    index(depth) {
      return this.path[this.resolveDepth(depth) * 3 + 1];
    }
    /**
    The index pointing after this position into the ancestor at the
    given level.
    */
    indexAfter(depth) {
      depth = this.resolveDepth(depth);
      return this.index(depth) + (depth == this.depth && !this.textOffset ? 0 : 1);
    }
    /**
    The (absolute) position at the start of the node at the given
    level.
    */
    start(depth) {
      depth = this.resolveDepth(depth);
      return depth == 0 ? 0 : this.path[depth * 3 - 1] + 1;
    }
    /**
    The (absolute) position at the end of the node at the given
    level.
    */
    end(depth) {
      depth = this.resolveDepth(depth);
      return this.start(depth) + this.node(depth).content.size;
    }
    /**
    The (absolute) position directly before the wrapping node at the
    given level, or, when `depth` is `this.depth + 1`, the original
    position.
    */
    before(depth) {
      depth = this.resolveDepth(depth);
      if (!depth)
        throw new RangeError("There is no position before the top-level node");
      return depth == this.depth + 1 ? this.pos : this.path[depth * 3 - 1];
    }
    /**
    The (absolute) position directly after the wrapping node at the
    given level, or the original position when `depth` is `this.depth + 1`.
    */
    after(depth) {
      depth = this.resolveDepth(depth);
      if (!depth)
        throw new RangeError("There is no position after the top-level node");
      return depth == this.depth + 1 ? this.pos : this.path[depth * 3 - 1] + this.path[depth * 3].nodeSize;
    }
    /**
    When this position points into a text node, this returns the
    distance between the position and the start of the text node.
    Will be zero for positions that point between nodes.
    */
    get textOffset() {
      return this.pos - this.path[this.path.length - 1];
    }
    /**
    Get the node directly after the position, if any. If the position
    points into a text node, only the part of that node after the
    position is returned.
    */
    get nodeAfter() {
      let parent = this.parent, index = this.index(this.depth);
      if (index == parent.childCount)
        return null;
      let dOff = this.pos - this.path[this.path.length - 1], child = parent.child(index);
      return dOff ? parent.child(index).cut(dOff) : child;
    }
    /**
    Get the node directly before the position, if any. If the
    position points into a text node, only the part of that node
    before the position is returned.
    */
    get nodeBefore() {
      let index = this.index(this.depth);
      let dOff = this.pos - this.path[this.path.length - 1];
      if (dOff)
        return this.parent.child(index).cut(0, dOff);
      return index == 0 ? null : this.parent.child(index - 1);
    }
    /**
    Get the position at the given index in the parent node at the
    given depth (which defaults to `this.depth`).
    */
    posAtIndex(index, depth) {
      depth = this.resolveDepth(depth);
      let node = this.path[depth * 3], pos = depth == 0 ? 0 : this.path[depth * 3 - 1] + 1;
      for (let i = 0; i < index; i++)
        pos += node.child(i).nodeSize;
      return pos;
    }
    /**
    Get the marks at this position, factoring in the surrounding
    marks' [`inclusive`](https://prosemirror.net/docs/ref/#model.MarkSpec.inclusive) property. If the
    position is at the start of a non-empty node, the marks of the
    node after it (if any) are returned.
    */
    marks() {
      let parent = this.parent, index = this.index();
      if (parent.content.size == 0)
        return Mark.none;
      if (this.textOffset)
        return parent.child(index).marks;
      let main = parent.maybeChild(index - 1), other = parent.maybeChild(index);
      if (!main) {
        let tmp = main;
        main = other;
        other = tmp;
      }
      let marks2 = main.marks;
      for (var i = 0; i < marks2.length; i++)
        if (marks2[i].type.spec.inclusive === false && (!other || !marks2[i].isInSet(other.marks)))
          marks2 = marks2[i--].removeFromSet(marks2);
      return marks2;
    }
    /**
    Get the marks after the current position, if any, except those
    that are non-inclusive and not present at position `$end`. This
    is mostly useful for getting the set of marks to preserve after a
    deletion. Will return `null` if this position is at the end of
    its parent node or its parent node isn't a textblock (in which
    case no marks should be preserved).
    */
    marksAcross($end) {
      let after = this.parent.maybeChild(this.index());
      if (!after || !after.isInline)
        return null;
      let marks2 = after.marks, next = $end.parent.maybeChild($end.index());
      for (var i = 0; i < marks2.length; i++)
        if (marks2[i].type.spec.inclusive === false && (!next || !marks2[i].isInSet(next.marks)))
          marks2 = marks2[i--].removeFromSet(marks2);
      return marks2;
    }
    /**
    The depth up to which this position and the given (non-resolved)
    position share the same parent nodes.
    */
    sharedDepth(pos) {
      for (let depth = this.depth; depth > 0; depth--)
        if (this.start(depth) <= pos && this.end(depth) >= pos)
          return depth;
      return 0;
    }
    /**
    Returns a range based on the place where this position and the
    given position diverge around block content. If both point into
    the same textblock, for example, a range around that textblock
    will be returned. If they point into different blocks, the range
    around those blocks in their shared ancestor is returned. You can
    pass in an optional predicate that will be called with a parent
    node to see if a range into that parent is acceptable.
    */
    blockRange(other = this, pred) {
      if (other.pos < this.pos)
        return other.blockRange(this);
      for (let d = this.depth - (this.parent.inlineContent || this.pos == other.pos ? 1 : 0); d >= 0; d--)
        if (other.pos <= this.end(d) && (!pred || pred(this.node(d))))
          return new NodeRange(this, other, d);
      return null;
    }
    /**
    Query whether the given position shares the same parent node.
    */
    sameParent(other) {
      return this.pos - this.parentOffset == other.pos - other.parentOffset;
    }
    /**
    Return the greater of this and the given position.
    */
    max(other) {
      return other.pos > this.pos ? other : this;
    }
    /**
    Return the smaller of this and the given position.
    */
    min(other) {
      return other.pos < this.pos ? other : this;
    }
    /**
    @internal
    */
    toString() {
      let str = "";
      for (let i = 1; i <= this.depth; i++)
        str += (str ? "/" : "") + this.node(i).type.name + "_" + this.index(i - 1);
      return str + ":" + this.parentOffset;
    }
    /**
    @internal
    */
    static resolve(doc3, pos) {
      if (!(pos >= 0 && pos <= doc3.content.size))
        throw new RangeError("Position " + pos + " out of range");
      let path = [];
      let start = 0, parentOffset = pos;
      for (let node = doc3; ; ) {
        let { index, offset } = node.content.findIndex(parentOffset);
        let rem = parentOffset - offset;
        path.push(node, index, start + offset);
        if (!rem)
          break;
        node = node.child(index);
        if (node.isText)
          break;
        parentOffset = rem - 1;
        start += offset + 1;
      }
      return new _ResolvedPos(pos, path, parentOffset);
    }
    /**
    @internal
    */
    static resolveCached(doc3, pos) {
      let cache = resolveCache.get(doc3);
      if (cache) {
        for (let i = 0; i < cache.elts.length; i++) {
          let elt = cache.elts[i];
          if (elt.pos == pos)
            return elt;
        }
      } else {
        resolveCache.set(doc3, cache = new ResolveCache());
      }
      let result = cache.elts[cache.i] = _ResolvedPos.resolve(doc3, pos);
      cache.i = (cache.i + 1) % resolveCacheSize;
      return result;
    }
  };
  var ResolveCache = class {
    constructor() {
      this.elts = [];
      this.i = 0;
    }
  };
  var resolveCacheSize = 12;
  var resolveCache = /* @__PURE__ */ new WeakMap();
  var NodeRange = class {
    /**
    Construct a node range. `$from` and `$to` should point into the
    same node until at least the given `depth`, since a node range
    denotes an adjacent set of nodes in a single parent node.
    */
    constructor($from, $to, depth) {
      this.$from = $from;
      this.$to = $to;
      this.depth = depth;
    }
    /**
    The position at the start of the range.
    */
    get start() {
      return this.$from.before(this.depth + 1);
    }
    /**
    The position at the end of the range.
    */
    get end() {
      return this.$to.after(this.depth + 1);
    }
    /**
    The parent node that the range points into.
    */
    get parent() {
      return this.$from.node(this.depth);
    }
    /**
    The start index of the range in the parent node.
    */
    get startIndex() {
      return this.$from.index(this.depth);
    }
    /**
    The end index of the range in the parent node.
    */
    get endIndex() {
      return this.$to.indexAfter(this.depth);
    }
  };
  var emptyAttrs = /* @__PURE__ */ Object.create(null);
  var Node = class _Node {
    /**
    @internal
    */
    constructor(type, attrs, content, marks2 = Mark.none) {
      this.type = type;
      this.attrs = attrs;
      this.marks = marks2;
      this.content = content || Fragment.empty;
    }
    /**
    The array of this node's child nodes.
    */
    get children() {
      return this.content.content;
    }
    /**
    The size of this node, as defined by the integer-based [indexing
    scheme](https://prosemirror.net/docs/guide/#doc.indexing). For text nodes, this is the
    amount of characters. For other leaf nodes, it is one. For
    non-leaf nodes, it is the size of the content plus two (the
    start and end token).
    */
    get nodeSize() {
      return this.isLeaf ? 1 : 2 + this.content.size;
    }
    /**
    The number of children that the node has.
    */
    get childCount() {
      return this.content.childCount;
    }
    /**
    Get the child node at the given index. Raises an error when the
    index is out of range.
    */
    child(index) {
      return this.content.child(index);
    }
    /**
    Get the child node at the given index, if it exists.
    */
    maybeChild(index) {
      return this.content.maybeChild(index);
    }
    /**
    Call `f` for every child node, passing the node, its offset
    into this parent node, and its index.
    */
    forEach(f) {
      this.content.forEach(f);
    }
    /**
    Invoke a callback for all descendant nodes recursively overlapping
    the given two positions that are relative to start of this
    node's content. This includes all ancestors of the nodes
    containing the two positions. The callback is invoked with the
    node, its position relative to the original node (method receiver),
    its parent node, and its child index. When the callback returns
    false for a given node, that node's children will not be
    recursed over. The last parameter can be used to specify a
    starting position to count from.
    */
    nodesBetween(from2, to, f, startPos = 0) {
      this.content.nodesBetween(from2, to, f, startPos, this);
    }
    /**
    Call the given callback for every descendant node. Doesn't
    descend into a node when the callback returns `false`.
    */
    descendants(f) {
      this.nodesBetween(0, this.content.size, f);
    }
    /**
    Concatenates all the text nodes found in this fragment and its
    children.
    */
    get textContent() {
      return this.isLeaf && this.type.spec.leafText ? this.type.spec.leafText(this) : this.textBetween(0, this.content.size, "");
    }
    /**
    Get all text between positions `from` and `to`. When
    `blockSeparator` is given, it will be inserted to separate text
    from different block nodes. If `leafText` is given, it'll be
    inserted for every non-text leaf node encountered, otherwise
    [`leafText`](https://prosemirror.net/docs/ref/#model.NodeSpec.leafText) will be used.
    */
    textBetween(from2, to, blockSeparator, leafText) {
      return this.content.textBetween(from2, to, blockSeparator, leafText);
    }
    /**
    Returns this node's first child, or `null` if there are no
    children.
    */
    get firstChild() {
      return this.content.firstChild;
    }
    /**
    Returns this node's last child, or `null` if there are no
    children.
    */
    get lastChild() {
      return this.content.lastChild;
    }
    /**
    Test whether two nodes represent the same piece of document.
    */
    eq(other) {
      return this == other || this.sameMarkup(other) && this.content.eq(other.content);
    }
    /**
    Compare the markup (type, attributes, and marks) of this node to
    those of another. Returns `true` if both have the same markup.
    */
    sameMarkup(other) {
      return this.hasMarkup(other.type, other.attrs, other.marks);
    }
    /**
    Check whether this node's markup correspond to the given type,
    attributes, and marks.
    */
    hasMarkup(type, attrs, marks2) {
      return this.type == type && compareDeep(this.attrs, attrs || type.defaultAttrs || emptyAttrs) && Mark.sameSet(this.marks, marks2 || Mark.none);
    }
    /**
    Create a new node with the same markup as this node, containing
    the given content (or empty, if no content is given).
    */
    copy(content = null) {
      if (content == this.content)
        return this;
      return new _Node(this.type, this.attrs, content, this.marks);
    }
    /**
    Create a copy of this node, with the given set of marks instead
    of the node's own marks.
    */
    mark(marks2) {
      return marks2 == this.marks ? this : new _Node(this.type, this.attrs, this.content, marks2);
    }
    /**
    Create a copy of this node with only the content between the
    given positions. If `to` is not given, it defaults to the end of
    the node.
    */
    cut(from2, to = this.content.size) {
      if (from2 == 0 && to == this.content.size)
        return this;
      return this.copy(this.content.cut(from2, to));
    }
    /**
    Cut out the part of the document between the given positions, and
    return it as a `Slice` object.
    */
    slice(from2, to = this.content.size, includeParents = false) {
      if (from2 == to)
        return Slice.empty;
      let $from = this.resolve(from2), $to = this.resolve(to);
      let depth = includeParents ? 0 : $from.sharedDepth(to);
      let start = $from.start(depth), node = $from.node(depth);
      let content = node.content.cut($from.pos - start, $to.pos - start);
      return new Slice(content, $from.depth - depth, $to.depth - depth);
    }
    /**
    Replace the part of the document between the given positions with
    the given slice. The slice must 'fit', meaning its open sides
    must be able to connect to the surrounding content, and its
    content nodes must be valid children for the node they are placed
    into. If any of this is violated, an error of type
    [`ReplaceError`](https://prosemirror.net/docs/ref/#model.ReplaceError) is thrown.
    */
    replace(from2, to, slice2) {
      return replace(this.resolve(from2), this.resolve(to), slice2);
    }
    /**
    Find the node directly after the given position.
    */
    nodeAt(pos) {
      for (let node = this; ; ) {
        let { index, offset } = node.content.findIndex(pos);
        node = node.maybeChild(index);
        if (!node)
          return null;
        if (offset == pos || node.isText)
          return node;
        pos -= offset + 1;
      }
    }
    /**
    Find the (direct) child node after the given offset, if any,
    and return it along with its index and offset relative to this
    node.
    */
    childAfter(pos) {
      let { index, offset } = this.content.findIndex(pos);
      return { node: this.content.maybeChild(index), index, offset };
    }
    /**
    Find the (direct) child node before the given offset, if any,
    and return it along with its index and offset relative to this
    node.
    */
    childBefore(pos) {
      if (pos == 0)
        return { node: null, index: 0, offset: 0 };
      let { index, offset } = this.content.findIndex(pos);
      if (offset < pos)
        return { node: this.content.child(index), index, offset };
      let node = this.content.child(index - 1);
      return { node, index: index - 1, offset: offset - node.nodeSize };
    }
    /**
    Resolve the given position in the document, returning an
    [object](https://prosemirror.net/docs/ref/#model.ResolvedPos) with information about its context.
    */
    resolve(pos) {
      return ResolvedPos.resolveCached(this, pos);
    }
    /**
    @internal
    */
    resolveNoCache(pos) {
      return ResolvedPos.resolve(this, pos);
    }
    /**
    Test whether a given mark or mark type occurs in this document
    between the two given positions.
    */
    rangeHasMark(from2, to, type) {
      let found2 = false;
      if (to > from2)
        this.nodesBetween(from2, to, (node) => {
          if (type.isInSet(node.marks))
            found2 = true;
          return !found2;
        });
      return found2;
    }
    /**
    True when this is a block (non-inline node)
    */
    get isBlock() {
      return this.type.isBlock;
    }
    /**
    True when this is a textblock node, a block node with inline
    content.
    */
    get isTextblock() {
      return this.type.isTextblock;
    }
    /**
    True when this node allows inline content.
    */
    get inlineContent() {
      return this.type.inlineContent;
    }
    /**
    True when this is an inline node (a text node or a node that can
    appear among text).
    */
    get isInline() {
      return this.type.isInline;
    }
    /**
    True when this is a text node.
    */
    get isText() {
      return this.type.isText;
    }
    /**
    True when this is a leaf node.
    */
    get isLeaf() {
      return this.type.isLeaf;
    }
    /**
    True when this is an atom, i.e. when it does not have directly
    editable content. This is usually the same as `isLeaf`, but can
    be configured with the [`atom` property](https://prosemirror.net/docs/ref/#model.NodeSpec.atom)
    on a node's spec (typically used when the node is displayed as
    an uneditable [node view](https://prosemirror.net/docs/ref/#view.NodeView)).
    */
    get isAtom() {
      return this.type.isAtom;
    }
    /**
    Return a string representation of this node for debugging
    purposes.
    */
    toString() {
      if (this.type.spec.toDebugString)
        return this.type.spec.toDebugString(this);
      let name = this.type.name;
      if (this.content.size)
        name += "(" + this.content.toStringInner() + ")";
      return wrapMarks(this.marks, name);
    }
    /**
    Get the content match in this node at the given index.
    */
    contentMatchAt(index) {
      let match = this.type.contentMatch.matchFragment(this.content, 0, index);
      if (!match)
        throw new Error("Called contentMatchAt on a node with invalid content");
      return match;
    }
    /**
    Test whether replacing the range between `from` and `to` (by
    child index) with the given replacement fragment (which defaults
    to the empty fragment) would leave the node's content valid. You
    can optionally pass `start` and `end` indices into the
    replacement fragment.
    */
    canReplace(from2, to, replacement = Fragment.empty, start = 0, end = replacement.childCount) {
      let one = this.contentMatchAt(from2).matchFragment(replacement, start, end);
      let two = one && one.matchFragment(this.content, to);
      if (!two || !two.validEnd)
        return false;
      for (let i = start; i < end; i++)
        if (!this.type.allowsMarks(replacement.child(i).marks))
          return false;
      return true;
    }
    /**
    Test whether replacing the range `from` to `to` (by index) with
    a node of the given type would leave the node's content valid.
    */
    canReplaceWith(from2, to, type, marks2) {
      if (marks2 && !this.type.allowsMarks(marks2))
        return false;
      let start = this.contentMatchAt(from2).matchType(type);
      let end = start && start.matchFragment(this.content, to);
      return end ? end.validEnd : false;
    }
    /**
    Test whether the given node's content could be appended to this
    node. If that node is empty, this will only return true if there
    is at least one node type that can appear in both nodes (to avoid
    merging completely incompatible nodes).
    */
    canAppend(other) {
      if (other.content.size)
        return this.canReplace(this.childCount, this.childCount, other.content);
      else
        return this.type.compatibleContent(other.type);
    }
    /**
    Check whether this node and its descendants conform to the
    schema, and raise an exception when they do not.
    */
    check() {
      this.type.checkContent(this.content);
      checkAttrs(this.type.attrs, this.attrs, "node", this.type.name);
      let copy2 = Mark.none;
      for (let i = 0; i < this.marks.length; i++) {
        let mark = this.marks[i];
        checkAttrs(mark.type.attrs, mark.attrs, "mark", mark.type.name);
        copy2 = mark.addToSet(copy2);
      }
      if (!Mark.sameSet(copy2, this.marks))
        throw new RangeError(`Invalid collection of marks for node ${this.type.name}: ${this.marks.map((m) => m.type.name)}`);
      this.content.forEach((node) => node.check());
    }
    /**
    Return a JSON-serializeable representation of this node.
    */
    toJSON() {
      let obj = { type: this.type.name };
      for (let _ in this.attrs) {
        obj.attrs = this.attrs;
        break;
      }
      if (this.content.size)
        obj.content = this.content.toJSON();
      if (this.marks.length)
        obj.marks = this.marks.map((n) => n.toJSON());
      return obj;
    }
    /**
    Deserialize a node from its JSON representation.
    */
    static fromJSON(schema2, json) {
      if (!json)
        throw new RangeError("Invalid input for Node.fromJSON");
      let marks2 = void 0;
      if (json.marks) {
        if (!Array.isArray(json.marks))
          throw new RangeError("Invalid mark data for Node.fromJSON");
        marks2 = json.marks.map(schema2.markFromJSON);
      }
      if (json.type == "text") {
        if (typeof json.text != "string")
          throw new RangeError("Invalid text node in JSON");
        return schema2.text(json.text, marks2);
      }
      let content = Fragment.fromJSON(schema2, json.content);
      let node = schema2.nodeType(json.type).create(json.attrs, content, marks2);
      return node;
    }
  };
  Node.prototype.text = void 0;
  var v8InternHack = (() => {
    let { stack } = new Error("/");
    if (!stack || !/\n\s*at\s/.test(stack))
      return (s) => s;
    let obj = /* @__PURE__ */ Object.create(null);
    return (s) => {
      obj[s];
      return s;
    };
  })();
  var TextNode = class _TextNode extends Node {
    /**
    @internal
    */
    constructor(type, attrs, content, marks2) {
      super(type, attrs, null, marks2);
      if (!content)
        throw new RangeError("Empty text nodes are not allowed");
      this.text = content;
    }
    toString() {
      if (this.type.spec.toDebugString)
        return this.type.spec.toDebugString(this);
      return wrapMarks(this.marks, JSON.stringify(this.text));
    }
    get textContent() {
      return this.text;
    }
    textBetween(from2, to) {
      return v8InternHack(this.text.slice(from2, to));
    }
    get nodeSize() {
      return this.text.length;
    }
    mark(marks2) {
      return marks2 == this.marks ? this : new _TextNode(this.type, this.attrs, this.text, marks2);
    }
    withText(text) {
      if (text == this.text)
        return this;
      return new _TextNode(this.type, this.attrs, text, this.marks);
    }
    cut(from2 = 0, to = this.text.length) {
      if (from2 == 0 && to == this.text.length)
        return this;
      return this.withText(v8InternHack(this.text.slice(from2, to)));
    }
    eq(other) {
      return this.sameMarkup(other) && this.text == other.text;
    }
    toJSON() {
      let base2 = super.toJSON();
      base2.text = this.text;
      return base2;
    }
  };
  function wrapMarks(marks2, str) {
    for (let i = marks2.length - 1; i >= 0; i--)
      str = marks2[i].type.name + "(" + str + ")";
    return str;
  }
  function checkAttrs(attrs, values, type, name) {
    for (let attr in values)
      if (!(attr in attrs))
        throw new RangeError(`Unsupported attribute ${attr} for ${type} of type ${name}`);
    for (let attr in attrs) {
      if (attrs[attr].validate)
        attrs[attr].validate(values[attr]);
    }
  }
  var ContentMatch = class _ContentMatch {
    /**
    @internal
    */
    constructor(validEnd) {
      this.validEnd = validEnd;
      this.next = [];
      this.wrapCache = [];
    }
    /**
    @internal
    */
    static parse(string, nodeTypes) {
      let stream = new TokenStream(string, nodeTypes);
      if (stream.next == null)
        return _ContentMatch.empty;
      let expr = parseExpr(stream);
      if (stream.next)
        stream.err("Unexpected trailing text");
      let match = dfa(nfa(expr));
      checkForDeadEnds(match, stream);
      return match;
    }
    /**
    Match a node type, returning a match after that node if
    successful.
    */
    matchType(type) {
      for (let i = 0; i < this.next.length; i++)
        if (this.next[i].type == type)
          return this.next[i].next;
      return null;
    }
    /**
    Try to match a fragment. Returns the resulting match when
    successful.
    */
    matchFragment(frag, start = 0, end = frag.childCount) {
      let cur = this;
      for (let i = start; cur && i < end; i++)
        cur = cur.matchType(frag.child(i).type);
      return cur;
    }
    /**
    @internal
    */
    get inlineContent() {
      return this.next.length != 0 && this.next[0].type.isInline;
    }
    /**
    Get the first matching node type at this match position that can
    be generated.
    */
    get defaultType() {
      for (let i = 0; i < this.next.length; i++) {
        let { type } = this.next[i];
        if (!(type.isText || type.hasRequiredAttrs()))
          return type;
      }
      return null;
    }
    /**
    @internal
    */
    compatible(other) {
      for (let i = 0; i < this.next.length; i++)
        for (let j = 0; j < other.next.length; j++)
          if (this.next[i].type == other.next[j].type)
            return true;
      return false;
    }
    /**
    Try to match the given fragment, and if that fails, see if it can
    be made to match by inserting nodes in front of it. When
    successful, return a fragment of inserted nodes (which may be
    empty if nothing had to be inserted). When `toEnd` is true, only
    return a fragment if the resulting match goes to the end of the
    content expression.
    */
    fillBefore(after, toEnd = false, startIndex = 0) {
      let seen = [this];
      function search(match, types) {
        let finished = match.matchFragment(after, startIndex);
        if (finished && (!toEnd || finished.validEnd))
          return Fragment.from(types.map((tp) => tp.createAndFill()));
        for (let i = 0; i < match.next.length; i++) {
          let { type, next } = match.next[i];
          if (!(type.isText || type.hasRequiredAttrs()) && seen.indexOf(next) == -1) {
            seen.push(next);
            let found2 = search(next, types.concat(type));
            if (found2)
              return found2;
          }
        }
        return null;
      }
      return search(this, []);
    }
    /**
    Find a set of wrapping node types that would allow a node of the
    given type to appear at this position. The result may be empty
    (when it fits directly) and will be null when no such wrapping
    exists.
    */
    findWrapping(target) {
      for (let i = 0; i < this.wrapCache.length; i += 2)
        if (this.wrapCache[i] == target)
          return this.wrapCache[i + 1];
      let computed = this.computeWrapping(target);
      this.wrapCache.push(target, computed);
      return computed;
    }
    /**
    @internal
    */
    computeWrapping(target) {
      let seen = /* @__PURE__ */ Object.create(null), active = [{ match: this, type: null, via: null }];
      while (active.length) {
        let current = active.shift(), match = current.match;
        if (match.matchType(target)) {
          let result = [];
          for (let obj = current; obj.type; obj = obj.via)
            result.push(obj.type);
          return result.reverse();
        }
        for (let i = 0; i < match.next.length; i++) {
          let { type, next } = match.next[i];
          if (!type.isLeaf && !type.hasRequiredAttrs() && !(type.name in seen) && (!current.type || next.validEnd)) {
            active.push({ match: type.contentMatch, type, via: current });
            seen[type.name] = true;
          }
        }
      }
      return null;
    }
    /**
    The number of outgoing edges this node has in the finite
    automaton that describes the content expression.
    */
    get edgeCount() {
      return this.next.length;
    }
    /**
    Get the _n_​th outgoing edge from this node in the finite
    automaton that describes the content expression.
    */
    edge(n) {
      if (n >= this.next.length)
        throw new RangeError(`There's no ${n}th edge in this content match`);
      return this.next[n];
    }
    /**
    @internal
    */
    toString() {
      let seen = [];
      function scan(m) {
        seen.push(m);
        for (let i = 0; i < m.next.length; i++)
          if (seen.indexOf(m.next[i].next) == -1)
            scan(m.next[i].next);
      }
      scan(this);
      return seen.map((m, i) => {
        let out = i + (m.validEnd ? "*" : " ") + " ";
        for (let i2 = 0; i2 < m.next.length; i2++)
          out += (i2 ? ", " : "") + m.next[i2].type.name + "->" + seen.indexOf(m.next[i2].next);
        return out;
      }).join("\n");
    }
  };
  ContentMatch.empty = new ContentMatch(true);
  var TokenStream = class {
    constructor(string, nodeTypes) {
      this.string = string;
      this.nodeTypes = nodeTypes;
      this.inline = null;
      this.pos = 0;
      this.tokens = string.split(/\s*(?=\b|\W|$)/);
      if (this.tokens[this.tokens.length - 1] == "")
        this.tokens.pop();
      if (this.tokens[0] == "")
        this.tokens.shift();
    }
    get next() {
      return this.tokens[this.pos];
    }
    eat(tok) {
      return this.next == tok && (this.pos++ || true);
    }
    err(str) {
      throw new SyntaxError(str + " (in content expression '" + this.string + "')");
    }
  };
  function parseExpr(stream) {
    let exprs = [];
    do {
      exprs.push(parseExprSeq(stream));
    } while (stream.eat("|"));
    return exprs.length == 1 ? exprs[0] : { type: "choice", exprs };
  }
  function parseExprSeq(stream) {
    let exprs = [];
    do {
      exprs.push(parseExprSubscript(stream));
    } while (stream.next && stream.next != ")" && stream.next != "|");
    return exprs.length == 1 ? exprs[0] : { type: "seq", exprs };
  }
  function parseExprSubscript(stream) {
    let expr = parseExprAtom(stream);
    for (; ; ) {
      if (stream.eat("+"))
        expr = { type: "plus", expr };
      else if (stream.eat("*"))
        expr = { type: "star", expr };
      else if (stream.eat("?"))
        expr = { type: "opt", expr };
      else if (stream.eat("{"))
        expr = parseExprRange(stream, expr);
      else
        break;
    }
    return expr;
  }
  function parseNum(stream) {
    if (/\D/.test(stream.next))
      stream.err("Expected number, got '" + stream.next + "'");
    let result = Number(stream.next);
    stream.pos++;
    return result;
  }
  function parseExprRange(stream, expr) {
    let min = parseNum(stream), max = min;
    if (stream.eat(",")) {
      if (stream.next != "}")
        max = parseNum(stream);
      else
        max = -1;
    }
    if (!stream.eat("}"))
      stream.err("Unclosed braced range");
    return { type: "range", min, max, expr };
  }
  function resolveName(stream, name) {
    let types = stream.nodeTypes, type = types[name];
    if (type)
      return [type];
    let result = [];
    for (let typeName in types) {
      let type2 = types[typeName];
      if (type2.isInGroup(name))
        result.push(type2);
    }
    if (result.length == 0)
      stream.err("No node type or group '" + name + "' found");
    return result;
  }
  function parseExprAtom(stream) {
    if (stream.eat("(")) {
      let expr = parseExpr(stream);
      if (!stream.eat(")"))
        stream.err("Missing closing paren");
      return expr;
    } else if (!/\W/.test(stream.next)) {
      let exprs = resolveName(stream, stream.next).map((type) => {
        if (stream.inline == null)
          stream.inline = type.isInline;
        else if (stream.inline != type.isInline)
          stream.err("Mixing inline and block content");
        return { type: "name", value: type };
      });
      stream.pos++;
      return exprs.length == 1 ? exprs[0] : { type: "choice", exprs };
    } else {
      stream.err("Unexpected token '" + stream.next + "'");
    }
  }
  function nfa(expr) {
    let nfa2 = [[]];
    connect(compile(expr, 0), node());
    return nfa2;
    function node() {
      return nfa2.push([]) - 1;
    }
    function edge(from2, to, term) {
      let edge2 = { term, to };
      nfa2[from2].push(edge2);
      return edge2;
    }
    function connect(edges, to) {
      edges.forEach((edge2) => edge2.to = to);
    }
    function compile(expr2, from2) {
      if (expr2.type == "choice") {
        return expr2.exprs.reduce((out, expr3) => out.concat(compile(expr3, from2)), []);
      } else if (expr2.type == "seq") {
        for (let i = 0; ; i++) {
          let next = compile(expr2.exprs[i], from2);
          if (i == expr2.exprs.length - 1)
            return next;
          connect(next, from2 = node());
        }
      } else if (expr2.type == "star") {
        let loop = node();
        edge(from2, loop);
        connect(compile(expr2.expr, loop), loop);
        return [edge(loop)];
      } else if (expr2.type == "plus") {
        let loop = node();
        connect(compile(expr2.expr, from2), loop);
        connect(compile(expr2.expr, loop), loop);
        return [edge(loop)];
      } else if (expr2.type == "opt") {
        return [edge(from2)].concat(compile(expr2.expr, from2));
      } else if (expr2.type == "range") {
        let cur = from2;
        for (let i = 0; i < expr2.min; i++) {
          let next = node();
          connect(compile(expr2.expr, cur), next);
          cur = next;
        }
        if (expr2.max == -1) {
          connect(compile(expr2.expr, cur), cur);
        } else {
          for (let i = expr2.min; i < expr2.max; i++) {
            let next = node();
            edge(cur, next);
            connect(compile(expr2.expr, cur), next);
            cur = next;
          }
        }
        return [edge(cur)];
      } else if (expr2.type == "name") {
        return [edge(from2, void 0, expr2.value)];
      } else {
        throw new Error("Unknown expr type");
      }
    }
  }
  function cmp(a, b) {
    return b - a;
  }
  function nullFrom(nfa2, node) {
    let result = [];
    scan(node);
    return result.sort(cmp);
    function scan(node2) {
      let edges = nfa2[node2];
      if (edges.length == 1 && !edges[0].term)
        return scan(edges[0].to);
      result.push(node2);
      for (let i = 0; i < edges.length; i++) {
        let { term, to } = edges[i];
        if (!term && result.indexOf(to) == -1)
          scan(to);
      }
    }
  }
  function dfa(nfa2) {
    let labeled = /* @__PURE__ */ Object.create(null);
    return explore(nullFrom(nfa2, 0));
    function explore(states) {
      let out = [];
      states.forEach((node) => {
        nfa2[node].forEach(({ term, to }) => {
          if (!term)
            return;
          let set;
          for (let i = 0; i < out.length; i++)
            if (out[i][0] == term)
              set = out[i][1];
          nullFrom(nfa2, to).forEach((node2) => {
            if (!set)
              out.push([term, set = []]);
            if (set.indexOf(node2) == -1)
              set.push(node2);
          });
        });
      });
      let state = labeled[states.join(",")] = new ContentMatch(states.indexOf(nfa2.length - 1) > -1);
      for (let i = 0; i < out.length; i++) {
        let states2 = out[i][1].sort(cmp);
        state.next.push({ type: out[i][0], next: labeled[states2.join(",")] || explore(states2) });
      }
      return state;
    }
  }
  function checkForDeadEnds(match, stream) {
    for (let i = 0, work = [match]; i < work.length; i++) {
      let state = work[i], dead = !state.validEnd, nodes2 = [];
      for (let j = 0; j < state.next.length; j++) {
        let { type, next } = state.next[j];
        nodes2.push(type.name);
        if (dead && !(type.isText || type.hasRequiredAttrs()))
          dead = false;
        if (work.indexOf(next) == -1)
          work.push(next);
      }
      if (dead)
        stream.err("Only non-generatable nodes (" + nodes2.join(", ") + ") in a required position (see https://prosemirror.net/docs/guide/#generatable)");
    }
  }
  function defaultAttrs(attrs) {
    let defaults = /* @__PURE__ */ Object.create(null);
    for (let attrName in attrs) {
      let attr = attrs[attrName];
      if (!attr.hasDefault)
        return null;
      defaults[attrName] = attr.default;
    }
    return defaults;
  }
  function computeAttrs(attrs, value) {
    let built = /* @__PURE__ */ Object.create(null);
    for (let name in attrs) {
      let attr = attrs[name];
      let given = value && value[name];
      if (given === void 0) {
        if (attr.hasDefault)
          given = attr.default;
        else
          throw new RangeError("No value supplied for attribute " + name);
      } else if (attr.validate) {
        attr.validate(given);
      }
      built[name] = given;
    }
    return built;
  }
  function initAttrs(typeName, attrs) {
    let result = /* @__PURE__ */ Object.create(null);
    if (attrs)
      for (let name in attrs)
        result[name] = new Attribute(typeName, name, attrs[name]);
    return result;
  }
  var NodeType = class _NodeType {
    /**
    @internal
    */
    constructor(name, schema2, spec) {
      this.name = name;
      this.schema = schema2;
      this.spec = spec;
      this.markSet = null;
      this.groups = spec.group ? spec.group.split(" ") : [];
      this.attrs = initAttrs(name, spec.attrs);
      this.defaultAttrs = defaultAttrs(this.attrs);
      this.contentMatch = null;
      this.inlineContent = null;
      this.isBlock = !(spec.inline || name == "text");
      this.isText = name == "text";
    }
    /**
    True if this is an inline type.
    */
    get isInline() {
      return !this.isBlock;
    }
    /**
    True if this is a textblock type, a block that contains inline
    content.
    */
    get isTextblock() {
      return this.isBlock && this.inlineContent;
    }
    /**
    True for node types that allow no content.
    */
    get isLeaf() {
      return this.contentMatch == ContentMatch.empty;
    }
    /**
    True when this node is an atom, i.e. when it does not have
    directly editable content.
    */
    get isAtom() {
      return this.isLeaf || !!this.spec.atom;
    }
    /**
    Return true when this node type is part of the given
    [group](https://prosemirror.net/docs/ref/#model.NodeSpec.group).
    */
    isInGroup(group) {
      return this.groups.indexOf(group) > -1;
    }
    /**
    The node type's [whitespace](https://prosemirror.net/docs/ref/#model.NodeSpec.whitespace) option.
    */
    get whitespace() {
      return this.spec.whitespace || (this.spec.code ? "pre" : "normal");
    }
    /**
    Tells you whether this node type has any required attributes.
    */
    hasRequiredAttrs() {
      for (let n in this.attrs)
        if (this.attrs[n].isRequired)
          return true;
      return false;
    }
    /**
    Indicates whether this node allows some of the same content as
    the given node type.
    */
    compatibleContent(other) {
      return this == other || this.contentMatch.compatible(other.contentMatch);
    }
    /**
    @internal
    */
    computeAttrs(attrs) {
      if (!attrs && this.defaultAttrs)
        return this.defaultAttrs;
      else
        return computeAttrs(this.attrs, attrs);
    }
    /**
    Create a `Node` of this type. The given attributes are
    checked and defaulted (you can pass `null` to use the type's
    defaults entirely, if no required attributes exist). `content`
    may be a `Fragment`, a node, an array of nodes, or
    `null`. Similarly `marks` may be `null` to default to the empty
    set of marks.
    */
    create(attrs = null, content, marks2) {
      if (this.isText)
        throw new Error("NodeType.create can't construct text nodes");
      return new Node(this, this.computeAttrs(attrs), Fragment.from(content), Mark.setFrom(marks2));
    }
    /**
    Like [`create`](https://prosemirror.net/docs/ref/#model.NodeType.create), but check the given content
    against the node type's content restrictions, and throw an error
    if it doesn't match.
    */
    createChecked(attrs = null, content, marks2) {
      content = Fragment.from(content);
      this.checkContent(content);
      return new Node(this, this.computeAttrs(attrs), content, Mark.setFrom(marks2));
    }
    /**
    Like [`create`](https://prosemirror.net/docs/ref/#model.NodeType.create), but see if it is
    necessary to add nodes to the start or end of the given fragment
    to make it fit the node. If no fitting wrapping can be found,
    return null. Note that, due to the fact that required nodes can
    always be created, this will always succeed if you pass null or
    `Fragment.empty` as content.
    */
    createAndFill(attrs = null, content, marks2) {
      attrs = this.computeAttrs(attrs);
      content = Fragment.from(content);
      if (content.size) {
        let before = this.contentMatch.fillBefore(content);
        if (!before)
          return null;
        content = before.append(content);
      }
      let matched = this.contentMatch.matchFragment(content);
      let after = matched && matched.fillBefore(Fragment.empty, true);
      if (!after)
        return null;
      return new Node(this, attrs, content.append(after), Mark.setFrom(marks2));
    }
    /**
    Returns true if the given fragment is valid content for this node
    type.
    */
    validContent(content) {
      let result = this.contentMatch.matchFragment(content);
      if (!result || !result.validEnd)
        return false;
      for (let i = 0; i < content.childCount; i++)
        if (!this.allowsMarks(content.child(i).marks))
          return false;
      return true;
    }
    /**
    Throws a RangeError if the given fragment is not valid content for this
    node type.
    @internal
    */
    checkContent(content) {
      if (!this.validContent(content))
        throw new RangeError(`Invalid content for node ${this.name}: ${content.toString().slice(0, 50)}`);
    }
    /**
    @internal no longer useful, but called by old prosemirror-view versions
    */
    checkAttrs(attrs) {
    }
    /**
    Check whether the given mark type is allowed in this node.
    */
    allowsMarkType(markType) {
      return this.markSet == null || this.markSet.indexOf(markType) > -1;
    }
    /**
    Test whether the given set of marks are allowed in this node.
    */
    allowsMarks(marks2) {
      if (this.markSet == null)
        return true;
      for (let i = 0; i < marks2.length; i++)
        if (!this.allowsMarkType(marks2[i].type))
          return false;
      return true;
    }
    /**
    Removes the marks that are not allowed in this node from the given set.
    */
    allowedMarks(marks2) {
      if (this.markSet == null)
        return marks2;
      let copy2;
      for (let i = 0; i < marks2.length; i++) {
        if (!this.allowsMarkType(marks2[i].type)) {
          if (!copy2)
            copy2 = marks2.slice(0, i);
        } else if (copy2) {
          copy2.push(marks2[i]);
        }
      }
      return !copy2 ? marks2 : copy2.length ? copy2 : Mark.none;
    }
    /**
    @internal
    */
    static compile(nodes2, schema2) {
      let result = /* @__PURE__ */ Object.create(null);
      nodes2.forEach((name, spec) => result[name] = new _NodeType(name, schema2, spec));
      let topType = schema2.spec.topNode || "doc";
      if (!result[topType])
        throw new RangeError("Schema is missing its top node type ('" + topType + "')");
      if (!result.text)
        throw new RangeError("Every schema needs a 'text' type");
      for (let _ in result.text.attrs)
        throw new RangeError("The text node type should not have attributes");
      return result;
    }
  };
  function validateType(typeName, attrName, type) {
    let types = type.split("|");
    return (value) => {
      let name = value === null ? "null" : typeof value;
      if (types.indexOf(name) < 0)
        throw new RangeError(`Expected value of type ${types} for attribute ${attrName} on type ${typeName}, got ${name}`);
    };
  }
  var Attribute = class {
    constructor(typeName, attrName, options) {
      this.hasDefault = Object.prototype.hasOwnProperty.call(options, "default");
      this.default = options.default;
      this.validate = typeof options.validate == "string" ? validateType(typeName, attrName, options.validate) : options.validate;
    }
    get isRequired() {
      return !this.hasDefault;
    }
  };
  var MarkType = class _MarkType {
    /**
    @internal
    */
    constructor(name, rank, schema2, spec) {
      this.name = name;
      this.rank = rank;
      this.schema = schema2;
      this.spec = spec;
      this.attrs = initAttrs(name, spec.attrs);
      this.excluded = null;
      let defaults = defaultAttrs(this.attrs);
      this.instance = defaults ? new Mark(this, defaults) : null;
    }
    /**
    Create a mark of this type. `attrs` may be `null` or an object
    containing only some of the mark's attributes. The others, if
    they have defaults, will be added.
    */
    create(attrs = null) {
      if (!attrs && this.instance)
        return this.instance;
      return new Mark(this, computeAttrs(this.attrs, attrs));
    }
    /**
    @internal
    */
    static compile(marks2, schema2) {
      let result = /* @__PURE__ */ Object.create(null), rank = 0;
      marks2.forEach((name, spec) => result[name] = new _MarkType(name, rank++, schema2, spec));
      return result;
    }
    /**
    When there is a mark of this type in the given set, a new set
    without it is returned. Otherwise, the input set is returned.
    */
    removeFromSet(set) {
      for (var i = 0; i < set.length; i++)
        if (set[i].type == this) {
          set = set.slice(0, i).concat(set.slice(i + 1));
          i--;
        }
      return set;
    }
    /**
    Tests whether there is a mark of this type in the given set.
    */
    isInSet(set) {
      for (let i = 0; i < set.length; i++)
        if (set[i].type == this)
          return set[i];
    }
    /**
    Queries whether a given mark type is
    [excluded](https://prosemirror.net/docs/ref/#model.MarkSpec.excludes) by this one.
    */
    excludes(other) {
      return this.excluded.indexOf(other) > -1;
    }
  };
  var Schema = class {
    /**
    Construct a schema from a schema [specification](https://prosemirror.net/docs/ref/#model.SchemaSpec).
    */
    constructor(spec) {
      this.linebreakReplacement = null;
      this.cached = /* @__PURE__ */ Object.create(null);
      let instanceSpec = this.spec = {};
      for (let prop in spec)
        instanceSpec[prop] = spec[prop];
      instanceSpec.nodes = dist_default.from(spec.nodes), instanceSpec.marks = dist_default.from(spec.marks || {}), this.nodes = NodeType.compile(this.spec.nodes, this);
      this.marks = MarkType.compile(this.spec.marks, this);
      let contentExprCache = /* @__PURE__ */ Object.create(null);
      for (let prop in this.nodes) {
        if (prop in this.marks)
          throw new RangeError(prop + " can not be both a node and a mark");
        let type = this.nodes[prop], contentExpr = type.spec.content || "", markExpr = type.spec.marks;
        type.contentMatch = contentExprCache[contentExpr] || (contentExprCache[contentExpr] = ContentMatch.parse(contentExpr, this.nodes));
        type.inlineContent = type.contentMatch.inlineContent;
        if (type.spec.linebreakReplacement) {
          if (this.linebreakReplacement)
            throw new RangeError("Multiple linebreak nodes defined");
          if (!type.isInline || !type.isLeaf)
            throw new RangeError("Linebreak replacement nodes must be inline leaf nodes");
          this.linebreakReplacement = type;
        }
        type.markSet = markExpr == "_" ? null : markExpr ? gatherMarks(this, markExpr.split(" ")) : markExpr == "" || !type.inlineContent ? [] : null;
      }
      for (let prop in this.marks) {
        let type = this.marks[prop], excl = type.spec.excludes;
        type.excluded = excl == null ? [type] : excl == "" ? [] : gatherMarks(this, excl.split(" "));
      }
      this.nodeFromJSON = (json) => Node.fromJSON(this, json);
      this.markFromJSON = (json) => Mark.fromJSON(this, json);
      this.topNodeType = this.nodes[this.spec.topNode || "doc"];
      this.cached.wrappings = /* @__PURE__ */ Object.create(null);
    }
    /**
    Create a node in this schema. The `type` may be a string or a
    `NodeType` instance. Attributes will be extended with defaults,
    `content` may be a `Fragment`, `null`, a `Node`, or an array of
    nodes.
    */
    node(type, attrs = null, content, marks2) {
      if (typeof type == "string")
        type = this.nodeType(type);
      else if (!(type instanceof NodeType))
        throw new RangeError("Invalid node type: " + type);
      else if (type.schema != this)
        throw new RangeError("Node type from different schema used (" + type.name + ")");
      return type.createChecked(attrs, content, marks2);
    }
    /**
    Create a text node in the schema. Empty text nodes are not
    allowed.
    */
    text(text, marks2) {
      let type = this.nodes.text;
      return new TextNode(type, type.defaultAttrs, text, Mark.setFrom(marks2));
    }
    /**
    Create a mark with the given type and attributes.
    */
    mark(type, attrs) {
      if (typeof type == "string")
        type = this.marks[type];
      return type.create(attrs);
    }
    /**
    @internal
    */
    nodeType(name) {
      let found2 = this.nodes[name];
      if (!found2)
        throw new RangeError("Unknown node type: " + name);
      return found2;
    }
  };
  function gatherMarks(schema2, marks2) {
    let found2 = [];
    for (let i = 0; i < marks2.length; i++) {
      let name = marks2[i], mark = schema2.marks[name], ok = mark;
      if (mark) {
        found2.push(mark);
      } else {
        for (let prop in schema2.marks) {
          let mark2 = schema2.marks[prop];
          if (name == "_" || mark2.spec.group && mark2.spec.group.split(" ").indexOf(name) > -1)
            found2.push(ok = mark2);
        }
      }
      if (!ok)
        throw new SyntaxError("Unknown mark type: '" + marks2[i] + "'");
    }
    return found2;
  }
  function isTagRule(rule) {
    return rule.tag != null;
  }
  function isStyleRule(rule) {
    return rule.style != null;
  }
  var DOMParser = class _DOMParser {
    /**
    Create a parser that targets the given schema, using the given
    parsing rules.
    */
    constructor(schema2, rules) {
      this.schema = schema2;
      this.rules = rules;
      this.tags = [];
      this.styles = [];
      let matchedStyles = this.matchedStyles = [];
      rules.forEach((rule) => {
        if (isTagRule(rule)) {
          this.tags.push(rule);
        } else if (isStyleRule(rule)) {
          let prop = /[^=]*/.exec(rule.style)[0];
          if (matchedStyles.indexOf(prop) < 0)
            matchedStyles.push(prop);
          this.styles.push(rule);
        }
      });
      this.normalizeLists = !this.tags.some((r) => {
        if (!/^(ul|ol)\b/.test(r.tag) || !r.node)
          return false;
        let node = schema2.nodes[r.node];
        return node.contentMatch.matchType(node);
      });
    }
    /**
    Parse a document from the content of a DOM node.
    */
    parse(dom, options = {}) {
      let context = new ParseContext(this, options, false);
      context.addAll(dom, Mark.none, options.from, options.to);
      return context.finish();
    }
    /**
    Parses the content of the given DOM node, like
    [`parse`](https://prosemirror.net/docs/ref/#model.DOMParser.parse), and takes the same set of
    options. But unlike that method, which produces a whole node,
    this one returns a slice that is open at the sides, meaning that
    the schema constraints aren't applied to the start of nodes to
    the left of the input and the end of nodes at the end.
    */
    parseSlice(dom, options = {}) {
      let context = new ParseContext(this, options, true);
      context.addAll(dom, Mark.none, options.from, options.to);
      return Slice.maxOpen(context.finish());
    }
    /**
    @internal
    */
    matchTag(dom, context, after) {
      for (let i = after ? this.tags.indexOf(after) + 1 : 0; i < this.tags.length; i++) {
        let rule = this.tags[i];
        if (matches(dom, rule.tag) && (rule.namespace === void 0 || dom.namespaceURI == rule.namespace) && (!rule.context || context.matchesContext(rule.context))) {
          if (rule.getAttrs) {
            let result = rule.getAttrs(dom);
            if (result === false)
              continue;
            rule.attrs = result || void 0;
          }
          return rule;
        }
      }
    }
    /**
    @internal
    */
    matchStyle(prop, value, context, after) {
      for (let i = after ? this.styles.indexOf(after) + 1 : 0; i < this.styles.length; i++) {
        let rule = this.styles[i], style = rule.style;
        if (style.indexOf(prop) != 0 || rule.context && !context.matchesContext(rule.context) || // Test that the style string either precisely matches the prop,
        // or has an '=' sign after the prop, followed by the given
        // value.
        style.length > prop.length && (style.charCodeAt(prop.length) != 61 || style.slice(prop.length + 1) != value))
          continue;
        if (rule.getAttrs) {
          let result = rule.getAttrs(value);
          if (result === false)
            continue;
          rule.attrs = result || void 0;
        }
        return rule;
      }
    }
    /**
    @internal
    */
    static schemaRules(schema2) {
      let result = [];
      function insert(rule) {
        let priority = rule.priority == null ? 50 : rule.priority, i = 0;
        for (; i < result.length; i++) {
          let next = result[i], nextPriority = next.priority == null ? 50 : next.priority;
          if (nextPriority < priority)
            break;
        }
        result.splice(i, 0, rule);
      }
      for (let name in schema2.marks) {
        let rules = schema2.marks[name].spec.parseDOM;
        if (rules)
          rules.forEach((rule) => {
            insert(rule = copy(rule));
            if (!(rule.mark || rule.ignore || rule.clearMark))
              rule.mark = name;
          });
      }
      for (let name in schema2.nodes) {
        let rules = schema2.nodes[name].spec.parseDOM;
        if (rules)
          rules.forEach((rule) => {
            insert(rule = copy(rule));
            if (!(rule.node || rule.ignore || rule.mark))
              rule.node = name;
          });
      }
      return result;
    }
    /**
    Construct a DOM parser using the parsing rules listed in a
    schema's [node specs](https://prosemirror.net/docs/ref/#model.NodeSpec.parseDOM), reordered by
    [priority](https://prosemirror.net/docs/ref/#model.GenericParseRule.priority).
    */
    static fromSchema(schema2) {
      return schema2.cached.domParser || (schema2.cached.domParser = new _DOMParser(schema2, _DOMParser.schemaRules(schema2)));
    }
  };
  var blockTags = {
    address: true,
    article: true,
    aside: true,
    blockquote: true,
    body: true,
    canvas: true,
    dd: true,
    div: true,
    dl: true,
    fieldset: true,
    figcaption: true,
    figure: true,
    footer: true,
    form: true,
    h1: true,
    h2: true,
    h3: true,
    h4: true,
    h5: true,
    h6: true,
    header: true,
    hgroup: true,
    hr: true,
    li: true,
    noscript: true,
    ol: true,
    output: true,
    p: true,
    pre: true,
    section: true,
    table: true,
    tfoot: true,
    ul: true
  };
  var ignoreTags = {
    head: true,
    noscript: true,
    object: true,
    script: true,
    style: true,
    title: true
  };
  var listTags = { ol: true, ul: true };
  var OPT_PRESERVE_WS = 1;
  var OPT_PRESERVE_WS_FULL = 2;
  var OPT_OPEN_LEFT = 4;
  function wsOptionsFor(type, preserveWhitespace, base2) {
    if (preserveWhitespace != null)
      return (preserveWhitespace ? OPT_PRESERVE_WS : 0) | (preserveWhitespace === "full" ? OPT_PRESERVE_WS_FULL : 0);
    return type && type.whitespace == "pre" ? OPT_PRESERVE_WS | OPT_PRESERVE_WS_FULL : base2 & ~OPT_OPEN_LEFT;
  }
  var NodeContext = class {
    constructor(type, attrs, marks2, solid, match, options) {
      this.type = type;
      this.attrs = attrs;
      this.marks = marks2;
      this.solid = solid;
      this.options = options;
      this.content = [];
      this.activeMarks = Mark.none;
      this.match = match || (options & OPT_OPEN_LEFT ? null : type.contentMatch);
    }
    findWrapping(node) {
      if (!this.match) {
        if (!this.type)
          return [];
        let fill = this.type.contentMatch.fillBefore(Fragment.from(node));
        if (fill) {
          this.match = this.type.contentMatch.matchFragment(fill);
        } else {
          let start = this.type.contentMatch, wrap2;
          if (wrap2 = start.findWrapping(node.type)) {
            this.match = start;
            return wrap2;
          } else {
            return null;
          }
        }
      }
      return this.match.findWrapping(node.type);
    }
    finish(openEnd) {
      if (!(this.options & OPT_PRESERVE_WS)) {
        let last = this.content[this.content.length - 1], m;
        if (last && last.isText && (m = /[ \t\r\n\u000c]+$/.exec(last.text))) {
          let text = last;
          if (last.text.length == m[0].length)
            this.content.pop();
          else
            this.content[this.content.length - 1] = text.withText(text.text.slice(0, text.text.length - m[0].length));
        }
      }
      let content = Fragment.from(this.content);
      if (!openEnd && this.match)
        content = content.append(this.match.fillBefore(Fragment.empty, true));
      return this.type ? this.type.create(this.attrs, content, this.marks) : content;
    }
    inlineContext(node) {
      if (this.type)
        return this.type.inlineContent;
      if (this.content.length)
        return this.content[0].isInline;
      return node.parentNode && !blockTags.hasOwnProperty(node.parentNode.nodeName.toLowerCase());
    }
  };
  var ParseContext = class {
    constructor(parser, options, isOpen) {
      this.parser = parser;
      this.options = options;
      this.isOpen = isOpen;
      this.open = 0;
      this.localPreserveWS = false;
      let topNode = options.topNode, topContext;
      let topOptions = wsOptionsFor(null, options.preserveWhitespace, 0) | (isOpen ? OPT_OPEN_LEFT : 0);
      if (topNode)
        topContext = new NodeContext(topNode.type, topNode.attrs, Mark.none, true, options.topMatch || topNode.type.contentMatch, topOptions);
      else if (isOpen)
        topContext = new NodeContext(null, null, Mark.none, true, null, topOptions);
      else
        topContext = new NodeContext(parser.schema.topNodeType, null, Mark.none, true, null, topOptions);
      this.nodes = [topContext];
      this.find = options.findPositions;
      this.needsBlock = false;
    }
    get top() {
      return this.nodes[this.open];
    }
    // Add a DOM node to the content. Text is inserted as text node,
    // otherwise, the node is passed to `addElement` or, if it has a
    // `style` attribute, `addElementWithStyles`.
    addDOM(dom, marks2) {
      if (dom.nodeType == 3)
        this.addTextNode(dom, marks2);
      else if (dom.nodeType == 1)
        this.addElement(dom, marks2);
    }
    addTextNode(dom, marks2) {
      let value = dom.nodeValue;
      let top = this.top, preserveWS = top.options & OPT_PRESERVE_WS_FULL ? "full" : this.localPreserveWS || (top.options & OPT_PRESERVE_WS) > 0;
      let { schema: schema2 } = this.parser;
      if (preserveWS === "full" || top.inlineContext(dom) || /[^ \t\r\n\u000c]/.test(value)) {
        if (!preserveWS) {
          value = value.replace(/[ \t\r\n\u000c]+/g, " ");
          if (/^[ \t\r\n\u000c]/.test(value) && this.open == this.nodes.length - 1) {
            let nodeBefore = top.content[top.content.length - 1];
            let domNodeBefore = dom.previousSibling;
            if (!nodeBefore || domNodeBefore && domNodeBefore.nodeName == "BR" || nodeBefore.isText && /[ \t\r\n\u000c]$/.test(nodeBefore.text))
              value = value.slice(1);
          }
        } else if (preserveWS === "full") {
          value = value.replace(/\r\n?/g, "\n");
        } else if (schema2.linebreakReplacement && /[\r\n]/.test(value) && this.top.findWrapping(schema2.linebreakReplacement.create())) {
          let lines = value.split(/\r?\n|\r/);
          for (let i = 0; i < lines.length; i++) {
            if (i)
              this.insertNode(schema2.linebreakReplacement.create(), marks2, true);
            if (lines[i])
              this.insertNode(schema2.text(lines[i]), marks2, !/\S/.test(lines[i]));
          }
          value = "";
        } else {
          value = value.replace(/\r?\n|\r/g, " ");
        }
        if (value)
          this.insertNode(schema2.text(value), marks2, !/\S/.test(value));
        this.findInText(dom);
      } else {
        this.findInside(dom);
      }
    }
    // Try to find a handler for the given tag and use that to parse. If
    // none is found, the element's content nodes are added directly.
    addElement(dom, marks2, matchAfter) {
      let outerWS = this.localPreserveWS, top = this.top;
      if (dom.tagName == "PRE" || /pre/.test(dom.style && dom.style.whiteSpace))
        this.localPreserveWS = true;
      let name = dom.nodeName.toLowerCase(), ruleID;
      if (listTags.hasOwnProperty(name) && this.parser.normalizeLists)
        normalizeList(dom);
      let rule = this.options.ruleFromNode && this.options.ruleFromNode(dom) || (ruleID = this.parser.matchTag(dom, this, matchAfter));
      out: if (rule ? rule.ignore : ignoreTags.hasOwnProperty(name)) {
        this.findInside(dom);
        this.ignoreFallback(dom, marks2);
      } else if (!rule || rule.skip || rule.closeParent) {
        if (rule && rule.closeParent)
          this.open = Math.max(0, this.open - 1);
        else if (rule && rule.skip.nodeType)
          dom = rule.skip;
        let sync, oldNeedsBlock = this.needsBlock;
        if (blockTags.hasOwnProperty(name)) {
          if (top.content.length && top.content[0].isInline && this.open) {
            this.open--;
            top = this.top;
          }
          sync = true;
          if (!top.type)
            this.needsBlock = true;
        } else if (!dom.firstChild) {
          this.leafFallback(dom, marks2);
          break out;
        }
        let innerMarks = rule && rule.skip ? marks2 : this.readStyles(dom, marks2);
        if (innerMarks)
          this.addAll(dom, innerMarks);
        if (sync)
          this.sync(top);
        this.needsBlock = oldNeedsBlock;
      } else {
        let innerMarks = this.readStyles(dom, marks2);
        if (innerMarks)
          this.addElementByRule(dom, rule, innerMarks, rule.consuming === false ? ruleID : void 0);
      }
      this.localPreserveWS = outerWS;
    }
    // Called for leaf DOM nodes that would otherwise be ignored
    leafFallback(dom, marks2) {
      if (dom.nodeName == "BR" && this.top.type && this.top.type.inlineContent)
        this.addTextNode(dom.ownerDocument.createTextNode("\n"), marks2);
    }
    // Called for ignored nodes
    ignoreFallback(dom, marks2) {
      if (dom.nodeName == "BR" && (!this.top.type || !this.top.type.inlineContent))
        this.findPlace(this.parser.schema.text("-"), marks2, true);
    }
    // Run any style parser associated with the node's styles. Either
    // return an updated array of marks, or null to indicate some of the
    // styles had a rule with `ignore` set.
    readStyles(dom, marks2) {
      let styles = dom.style;
      if (styles && styles.length)
        for (let i = 0; i < this.parser.matchedStyles.length; i++) {
          let name = this.parser.matchedStyles[i], value = styles.getPropertyValue(name);
          if (value)
            for (let after = void 0; ; ) {
              let rule = this.parser.matchStyle(name, value, this, after);
              if (!rule)
                break;
              if (rule.ignore)
                return null;
              if (rule.clearMark)
                marks2 = marks2.filter((m) => !rule.clearMark(m));
              else
                marks2 = marks2.concat(this.parser.schema.marks[rule.mark].create(rule.attrs));
              if (rule.consuming === false)
                after = rule;
              else
                break;
            }
        }
      return marks2;
    }
    // Look up a handler for the given node. If none are found, return
    // false. Otherwise, apply it, use its return value to drive the way
    // the node's content is wrapped, and return true.
    addElementByRule(dom, rule, marks2, continueAfter) {
      let sync, nodeType;
      if (rule.node) {
        nodeType = this.parser.schema.nodes[rule.node];
        if (!nodeType.isLeaf) {
          let inner = this.enter(nodeType, rule.attrs || null, marks2, rule.preserveWhitespace);
          if (inner) {
            sync = true;
            marks2 = inner;
          }
        } else if (!this.insertNode(nodeType.create(rule.attrs), marks2, dom.nodeName == "BR")) {
          this.leafFallback(dom, marks2);
        }
      } else {
        let markType = this.parser.schema.marks[rule.mark];
        marks2 = marks2.concat(markType.create(rule.attrs));
      }
      let startIn = this.top;
      if (nodeType && nodeType.isLeaf) {
        this.findInside(dom);
      } else if (continueAfter) {
        this.addElement(dom, marks2, continueAfter);
      } else if (rule.getContent) {
        this.findInside(dom);
        rule.getContent(dom, this.parser.schema).forEach((node) => this.insertNode(node, marks2, false));
      } else {
        let contentDOM = dom;
        if (typeof rule.contentElement == "string")
          contentDOM = dom.querySelector(rule.contentElement);
        else if (typeof rule.contentElement == "function")
          contentDOM = rule.contentElement(dom);
        else if (rule.contentElement)
          contentDOM = rule.contentElement;
        this.findAround(dom, contentDOM, true);
        this.addAll(contentDOM, marks2);
        this.findAround(dom, contentDOM, false);
      }
      if (sync && this.sync(startIn))
        this.open--;
    }
    // Add all child nodes between `startIndex` and `endIndex` (or the
    // whole node, if not given). If `sync` is passed, use it to
    // synchronize after every block element.
    addAll(parent, marks2, startIndex, endIndex) {
      let index = startIndex || 0;
      for (let dom = startIndex ? parent.childNodes[startIndex] : parent.firstChild, end = endIndex == null ? null : parent.childNodes[endIndex]; dom != end; dom = dom.nextSibling, ++index) {
        this.findAtPoint(parent, index);
        this.addDOM(dom, marks2);
      }
      this.findAtPoint(parent, index);
    }
    // Try to find a way to fit the given node type into the current
    // context. May add intermediate wrappers and/or leave non-solid
    // nodes that we're in.
    findPlace(node, marks2, cautious) {
      let route, sync;
      for (let depth = this.open, penalty = 0; depth >= 0; depth--) {
        let cx = this.nodes[depth];
        let found2 = cx.findWrapping(node);
        if (found2 && (!route || route.length > found2.length + penalty)) {
          route = found2;
          sync = cx;
          if (!found2.length)
            break;
        }
        if (cx.solid) {
          if (cautious)
            break;
          penalty += 2;
        }
      }
      if (!route)
        return null;
      this.sync(sync);
      for (let i = 0; i < route.length; i++)
        marks2 = this.enterInner(route[i], null, marks2, false);
      return marks2;
    }
    // Try to insert the given node, adjusting the context when needed.
    insertNode(node, marks2, cautious) {
      if (node.isInline && this.needsBlock && !this.top.type) {
        let block = this.textblockFromContext();
        if (block)
          marks2 = this.enterInner(block, null, marks2);
      }
      let innerMarks = this.findPlace(node, marks2, cautious);
      if (innerMarks) {
        this.closeExtra();
        let top = this.top;
        if (top.match)
          top.match = top.match.matchType(node.type);
        let nodeMarks = Mark.none;
        for (let m of innerMarks.concat(node.marks))
          if (top.type ? top.type.allowsMarkType(m.type) : markMayApply(m.type, node.type))
            nodeMarks = m.addToSet(nodeMarks);
        top.content.push(node.mark(nodeMarks));
        return true;
      }
      return false;
    }
    // Try to start a node of the given type, adjusting the context when
    // necessary.
    enter(type, attrs, marks2, preserveWS) {
      let innerMarks = this.findPlace(type.create(attrs), marks2, false);
      if (innerMarks)
        innerMarks = this.enterInner(type, attrs, marks2, true, preserveWS);
      return innerMarks;
    }
    // Open a node of the given type
    enterInner(type, attrs, marks2, solid = false, preserveWS) {
      this.closeExtra();
      let top = this.top;
      top.match = top.match && top.match.matchType(type);
      let options = wsOptionsFor(type, preserveWS, top.options);
      if (top.options & OPT_OPEN_LEFT && top.content.length == 0)
        options |= OPT_OPEN_LEFT;
      let applyMarks = Mark.none;
      marks2 = marks2.filter((m) => {
        if (top.type ? top.type.allowsMarkType(m.type) : markMayApply(m.type, type)) {
          applyMarks = m.addToSet(applyMarks);
          return false;
        }
        return true;
      });
      this.nodes.push(new NodeContext(type, attrs, applyMarks, solid, null, options));
      this.open++;
      return marks2;
    }
    // Make sure all nodes above this.open are finished and added to
    // their parents
    closeExtra(openEnd = false) {
      let i = this.nodes.length - 1;
      if (i > this.open) {
        for (; i > this.open; i--)
          this.nodes[i - 1].content.push(this.nodes[i].finish(openEnd));
        this.nodes.length = this.open + 1;
      }
    }
    finish() {
      this.open = 0;
      this.closeExtra(this.isOpen);
      return this.nodes[0].finish(!!(this.isOpen || this.options.topOpen));
    }
    sync(to) {
      for (let i = this.open; i >= 0; i--) {
        if (this.nodes[i] == to) {
          this.open = i;
          return true;
        } else if (this.localPreserveWS) {
          this.nodes[i].options |= OPT_PRESERVE_WS;
        }
      }
      return false;
    }
    get currentPos() {
      this.closeExtra();
      let pos = 0;
      for (let i = this.open; i >= 0; i--) {
        let content = this.nodes[i].content;
        for (let j = content.length - 1; j >= 0; j--)
          pos += content[j].nodeSize;
        if (i)
          pos++;
      }
      return pos;
    }
    findAtPoint(parent, offset) {
      if (this.find)
        for (let i = 0; i < this.find.length; i++) {
          if (this.find[i].node == parent && this.find[i].offset == offset)
            this.find[i].pos = this.currentPos;
        }
    }
    findInside(parent) {
      if (this.find)
        for (let i = 0; i < this.find.length; i++) {
          if (this.find[i].pos == null && parent.nodeType == 1 && parent.contains(this.find[i].node))
            this.find[i].pos = this.currentPos;
        }
    }
    findAround(parent, content, before) {
      if (parent != content && this.find)
        for (let i = 0; i < this.find.length; i++) {
          if (this.find[i].pos == null && parent.nodeType == 1 && parent.contains(this.find[i].node)) {
            let pos = content.compareDocumentPosition(this.find[i].node);
            if (pos & (before ? 2 : 4))
              this.find[i].pos = this.currentPos;
          }
        }
    }
    findInText(textNode) {
      if (this.find)
        for (let i = 0; i < this.find.length; i++) {
          if (this.find[i].node == textNode)
            this.find[i].pos = this.currentPos - (textNode.nodeValue.length - this.find[i].offset);
        }
    }
    // Determines whether the given context string matches this context.
    matchesContext(context) {
      if (context.indexOf("|") > -1)
        return context.split(/\s*\|\s*/).some(this.matchesContext, this);
      let parts = context.split("/");
      let option = this.options.context;
      let useRoot = !this.isOpen && (!option || option.parent.type == this.nodes[0].type);
      let minDepth = -(option ? option.depth + 1 : 0) + (useRoot ? 0 : 1);
      let match = (i, depth) => {
        for (; i >= 0; i--) {
          let part = parts[i];
          if (part == "") {
            if (i == parts.length - 1 || i == 0)
              continue;
            for (; depth >= minDepth; depth--)
              if (match(i - 1, depth))
                return true;
            return false;
          } else {
            let next = depth > 0 || depth == 0 && useRoot ? this.nodes[depth].type : option && depth >= minDepth ? option.node(depth - minDepth).type : null;
            if (!next || next.name != part && !next.isInGroup(part))
              return false;
            depth--;
          }
        }
        return true;
      };
      return match(parts.length - 1, this.open);
    }
    textblockFromContext() {
      let $context = this.options.context;
      if ($context)
        for (let d = $context.depth; d >= 0; d--) {
          let deflt = $context.node(d).contentMatchAt($context.indexAfter(d)).defaultType;
          if (deflt && deflt.isTextblock && deflt.defaultAttrs)
            return deflt;
        }
      for (let name in this.parser.schema.nodes) {
        let type = this.parser.schema.nodes[name];
        if (type.isTextblock && type.defaultAttrs)
          return type;
      }
    }
  };
  function normalizeList(dom) {
    for (let child = dom.firstChild, prevItem = null; child; child = child.nextSibling) {
      let name = child.nodeType == 1 ? child.nodeName.toLowerCase() : null;
      if (name && listTags.hasOwnProperty(name) && prevItem) {
        prevItem.appendChild(child);
        child = prevItem;
      } else if (name == "li") {
        prevItem = child;
      } else if (name) {
        prevItem = null;
      }
    }
  }
  function matches(dom, selector) {
    return (dom.matches || dom.msMatchesSelector || dom.webkitMatchesSelector || dom.mozMatchesSelector).call(dom, selector);
  }
  function copy(obj) {
    let copy2 = {};
    for (let prop in obj)
      copy2[prop] = obj[prop];
    return copy2;
  }
  function markMayApply(markType, nodeType) {
    let nodes2 = nodeType.schema.nodes;
    for (let name in nodes2) {
      let parent = nodes2[name];
      if (!parent.allowsMarkType(markType))
        continue;
      let seen = [], scan = (match) => {
        seen.push(match);
        for (let i = 0; i < match.edgeCount; i++) {
          let { type, next } = match.edge(i);
          if (type == nodeType)
            return true;
          if (seen.indexOf(next) < 0 && scan(next))
            return true;
        }
      };
      if (scan(parent.contentMatch))
        return true;
    }
  }
  var DOMSerializer = class _DOMSerializer {
    /**
    Create a serializer. `nodes` should map node names to functions
    that take a node and return a description of the corresponding
    DOM. `marks` does the same for mark names, but also gets an
    argument that tells it whether the mark's content is block or
    inline content (for typical use, it'll always be inline). A mark
    serializer may be `null` to indicate that marks of that type
    should not be serialized.
    */
    constructor(nodes2, marks2) {
      this.nodes = nodes2;
      this.marks = marks2;
    }
    /**
    Serialize the content of this fragment to a DOM fragment. When
    not in the browser, the `document` option, containing a DOM
    document, should be passed so that the serializer can create
    nodes.
    */
    serializeFragment(fragment, options = {}, target) {
      if (!target)
        target = doc(options).createDocumentFragment();
      let top = target, active = [];
      fragment.forEach((node) => {
        if (active.length || node.marks.length) {
          let keep = 0, rendered = 0;
          while (keep < active.length && rendered < node.marks.length) {
            let next = node.marks[rendered];
            if (!this.marks[next.type.name]) {
              rendered++;
              continue;
            }
            if (!next.eq(active[keep][0]) || next.type.spec.spanning === false)
              break;
            keep++;
            rendered++;
          }
          while (keep < active.length)
            top = active.pop()[1];
          while (rendered < node.marks.length) {
            let add = node.marks[rendered++];
            let markDOM = this.serializeMark(add, node.isInline, options);
            if (markDOM) {
              active.push([add, top]);
              top.appendChild(markDOM.dom);
              top = markDOM.contentDOM || markDOM.dom;
            }
          }
        }
        top.appendChild(this.serializeNodeInner(node, options));
      });
      return target;
    }
    /**
    @internal
    */
    serializeNodeInner(node, options) {
      if (node.isText)
        return doc(options).createTextNode(node.text);
      let { dom, contentDOM } = renderSpec(doc(options), this.nodes[node.type.name](node), null, node.attrs);
      if (contentDOM) {
        if (node.isLeaf)
          throw new RangeError("Content hole not allowed in a leaf node spec");
        this.serializeFragment(node.content, options, contentDOM);
      }
      return dom;
    }
    /**
    Serialize this node to a DOM node. This can be useful when you
    need to serialize a part of a document, as opposed to the whole
    document. To serialize a whole document, use
    [`serializeFragment`](https://prosemirror.net/docs/ref/#model.DOMSerializer.serializeFragment) on
    its [content](https://prosemirror.net/docs/ref/#model.Node.content).
    */
    serializeNode(node, options = {}) {
      let dom = this.serializeNodeInner(node, options);
      for (let i = node.marks.length - 1; i >= 0; i--) {
        let wrap2 = this.serializeMark(node.marks[i], node.isInline, options);
        if (wrap2) {
          (wrap2.contentDOM || wrap2.dom).appendChild(dom);
          dom = wrap2.dom;
        }
      }
      return dom;
    }
    /**
    @internal
    */
    serializeMark(mark, inline, options = {}) {
      let toDOM = this.marks[mark.type.name];
      return toDOM && renderSpec(doc(options), toDOM(mark, inline), null, mark.attrs);
    }
    static renderSpec(doc3, structure, xmlNS = null, blockArraysIn) {
      if (typeof structure == "string")
        return { dom: doc3.createTextNode(structure) };
      return renderSpec(doc3, structure, xmlNS, blockArraysIn);
    }
    /**
    Build a serializer using the [`toDOM`](https://prosemirror.net/docs/ref/#model.NodeSpec.toDOM)
    properties in a schema's node and mark specs.
    */
    static fromSchema(schema2) {
      return schema2.cached.domSerializer || (schema2.cached.domSerializer = new _DOMSerializer(this.nodesFromSchema(schema2), this.marksFromSchema(schema2)));
    }
    /**
    Gather the serializers in a schema's node specs into an object.
    This can be useful as a base to build a custom serializer from.
    */
    static nodesFromSchema(schema2) {
      let result = gatherToDOM(schema2.nodes);
      if (!result.text)
        result.text = (node) => node.text;
      return result;
    }
    /**
    Gather the serializers in a schema's mark specs into an object.
    */
    static marksFromSchema(schema2) {
      return gatherToDOM(schema2.marks);
    }
  };
  function gatherToDOM(obj) {
    let result = {};
    for (let name in obj) {
      let toDOM = obj[name].spec.toDOM;
      if (toDOM)
        result[name] = toDOM;
    }
    return result;
  }
  function doc(options) {
    return options.document || window.document;
  }
  var suspiciousAttributeCache = /* @__PURE__ */ new WeakMap();
  function suspiciousAttributes(attrs) {
    let value = suspiciousAttributeCache.get(attrs);
    if (value === void 0)
      suspiciousAttributeCache.set(attrs, value = suspiciousAttributesInner(attrs));
    return value;
  }
  function suspiciousAttributesInner(attrs) {
    let result = null;
    function scan(value) {
      if (value && typeof value == "object") {
        if (Array.isArray(value)) {
          if (typeof value[0] == "string") {
            if (!result)
              result = [];
            result.push(value);
          } else {
            for (let i = 0; i < value.length; i++)
              scan(value[i]);
          }
        } else {
          for (let prop in value)
            scan(value[prop]);
        }
      }
    }
    scan(attrs);
    return result;
  }
  function renderSpec(doc3, structure, xmlNS, blockArraysIn) {
    if (structure.nodeType == 1)
      return { dom: structure };
    if (structure.dom && structure.dom.nodeType == 1)
      return structure;
    let tagName = structure[0], suspicious;
    if (typeof tagName != "string")
      throw new RangeError("Invalid array passed to renderSpec");
    if (blockArraysIn && (suspicious = suspiciousAttributes(blockArraysIn)) && suspicious.indexOf(structure) > -1)
      throw new RangeError("Using an array from an attribute object as a DOM spec. This may be an attempted cross site scripting attack.");
    let space = tagName.indexOf(" ");
    if (space > 0) {
      xmlNS = tagName.slice(0, space);
      tagName = tagName.slice(space + 1);
    }
    let contentDOM;
    let dom = xmlNS ? doc3.createElementNS(xmlNS, tagName) : doc3.createElement(tagName);
    let attrs = structure[1], start = 1;
    if (attrs && typeof attrs == "object" && attrs.nodeType == null && !Array.isArray(attrs)) {
      start = 2;
      for (let name in attrs)
        if (attrs[name] != null) {
          let space2 = name.indexOf(" ");
          if (space2 > 0)
            dom.setAttributeNS(name.slice(0, space2), name.slice(space2 + 1), attrs[name]);
          else if (name == "style" && dom.style)
            dom.style.cssText = attrs[name];
          else
            dom.setAttribute(name, attrs[name]);
        }
    }
    for (let i = start; i < structure.length; i++) {
      let child = structure[i];
      if (child === 0) {
        if (i < structure.length - 1 || i > start)
          throw new RangeError("Content hole must be the only child of its parent node");
        return { dom, contentDOM: dom };
      } else if (typeof child == "string") {
        dom.appendChild(doc3.createTextNode(child));
      } else {
        let { dom: inner, contentDOM: innerContent } = renderSpec(doc3, child, xmlNS, blockArraysIn);
        dom.appendChild(inner);
        if (innerContent) {
          if (contentDOM)
            throw new RangeError("Multiple content holes");
          contentDOM = innerContent;
        }
      }
    }
    return { dom, contentDOM };
  }

  // node_modules/prosemirror-transform/dist/index.js
  var lower16 = 65535;
  var factor16 = Math.pow(2, 16);
  function makeRecover(index, offset) {
    return index + offset * factor16;
  }
  function recoverIndex(value) {
    return value & lower16;
  }
  function recoverOffset(value) {
    return (value - (value & lower16)) / factor16;
  }
  var DEL_BEFORE = 1;
  var DEL_AFTER = 2;
  var DEL_ACROSS = 4;
  var DEL_SIDE = 8;
  var MapResult = class {
    /**
    @internal
    */
    constructor(pos, delInfo, recover) {
      this.pos = pos;
      this.delInfo = delInfo;
      this.recover = recover;
    }
    /**
    Tells you whether the position was deleted, that is, whether the
    step removed the token on the side queried (via the `assoc`)
    argument from the document.
    */
    get deleted() {
      return (this.delInfo & DEL_SIDE) > 0;
    }
    /**
    Tells you whether the token before the mapped position was deleted.
    */
    get deletedBefore() {
      return (this.delInfo & (DEL_BEFORE | DEL_ACROSS)) > 0;
    }
    /**
    True when the token after the mapped position was deleted.
    */
    get deletedAfter() {
      return (this.delInfo & (DEL_AFTER | DEL_ACROSS)) > 0;
    }
    /**
    Tells whether any of the steps mapped through deletes across the
    position (including both the token before and after the
    position).
    */
    get deletedAcross() {
      return (this.delInfo & DEL_ACROSS) > 0;
    }
  };
  var StepMap = class _StepMap {
    /**
    Create a position map. The modifications to the document are
    represented as an array of numbers, in which each group of three
    represents a modified chunk as `[start, oldSize, newSize]`.
    */
    constructor(ranges, inverted = false) {
      this.ranges = ranges;
      this.inverted = inverted;
      if (!ranges.length && _StepMap.empty)
        return _StepMap.empty;
    }
    /**
    @internal
    */
    recover(value) {
      let diff = 0, index = recoverIndex(value);
      if (!this.inverted)
        for (let i = 0; i < index; i++)
          diff += this.ranges[i * 3 + 2] - this.ranges[i * 3 + 1];
      return this.ranges[index * 3] + diff + recoverOffset(value);
    }
    mapResult(pos, assoc = 1) {
      return this._map(pos, assoc, false);
    }
    map(pos, assoc = 1) {
      return this._map(pos, assoc, true);
    }
    /**
    @internal
    */
    _map(pos, assoc, simple) {
      let diff = 0, oldIndex = this.inverted ? 2 : 1, newIndex = this.inverted ? 1 : 2;
      for (let i = 0; i < this.ranges.length; i += 3) {
        let start = this.ranges[i] - (this.inverted ? diff : 0);
        if (start > pos)
          break;
        let oldSize = this.ranges[i + oldIndex], newSize = this.ranges[i + newIndex], end = start + oldSize;
        if (pos <= end) {
          let side = !oldSize ? assoc : pos == start ? -1 : pos == end ? 1 : assoc;
          let result = start + diff + (side < 0 ? 0 : newSize);
          if (simple)
            return result;
          let recover = pos == (assoc < 0 ? start : end) ? null : makeRecover(i / 3, pos - start);
          let del2 = 0;
          if (oldSize) {
            del2 |= pos == start ? DEL_AFTER : pos == end ? DEL_BEFORE : DEL_ACROSS;
            if (assoc < 0 ? pos != start : pos != end)
              del2 |= DEL_SIDE;
          }
          return new MapResult(result, del2, recover);
        }
        diff += newSize - oldSize;
      }
      return simple ? pos + diff : new MapResult(pos + diff, 0, null);
    }
    /**
    @internal
    */
    touches(pos, recover) {
      let diff = 0, index = recoverIndex(recover);
      let oldIndex = this.inverted ? 2 : 1, newIndex = this.inverted ? 1 : 2;
      for (let i = 0; i < this.ranges.length; i += 3) {
        let start = this.ranges[i] - (this.inverted ? diff : 0);
        if (start > pos)
          break;
        let oldSize = this.ranges[i + oldIndex], end = start + oldSize;
        if (pos <= end && i == index * 3)
          return true;
        diff += this.ranges[i + newIndex] - oldSize;
      }
      return false;
    }
    /**
    Calls the given function on each of the changed ranges included in
    this map.
    */
    forEach(f) {
      let oldIndex = this.inverted ? 2 : 1, newIndex = this.inverted ? 1 : 2;
      for (let i = 0, diff = 0; i < this.ranges.length; i += 3) {
        let start = this.ranges[i], oldStart = start - (this.inverted ? diff : 0), newStart = start + (this.inverted ? 0 : diff);
        let oldSize = this.ranges[i + oldIndex], newSize = this.ranges[i + newIndex];
        f(oldStart, oldStart + oldSize, newStart, newStart + newSize);
        diff += newSize - oldSize;
      }
    }
    /**
    Create an inverted version of this map. The result can be used to
    map positions in the post-step document to the pre-step document.
    */
    invert() {
      return new _StepMap(this.ranges, !this.inverted);
    }
    /**
    @internal
    */
    toString() {
      return (this.inverted ? "-" : "") + JSON.stringify(this.ranges);
    }
    /**
    Create a map that moves all positions by offset `n` (which may be
    negative). This can be useful when applying steps meant for a
    sub-document to a larger document, or vice-versa.
    */
    static offset(n) {
      return n == 0 ? _StepMap.empty : new _StepMap(n < 0 ? [0, -n, 0] : [0, 0, n]);
    }
  };
  StepMap.empty = new StepMap([]);
  var Mapping = class _Mapping {
    /**
    Create a new mapping with the given position maps.
    */
    constructor(maps, mirror, from2 = 0, to = maps ? maps.length : 0) {
      this.mirror = mirror;
      this.from = from2;
      this.to = to;
      this._maps = maps || [];
      this.ownData = !(maps || mirror);
    }
    /**
    The step maps in this mapping.
    */
    get maps() {
      return this._maps;
    }
    /**
    Create a mapping that maps only through a part of this one.
    */
    slice(from2 = 0, to = this.maps.length) {
      return new _Mapping(this._maps, this.mirror, from2, to);
    }
    /**
    Add a step map to the end of this mapping. If `mirrors` is
    given, it should be the index of the step map that is the mirror
    image of this one.
    */
    appendMap(map2, mirrors) {
      if (!this.ownData) {
        this._maps = this._maps.slice();
        this.mirror = this.mirror && this.mirror.slice();
        this.ownData = true;
      }
      this.to = this._maps.push(map2);
      if (mirrors != null)
        this.setMirror(this._maps.length - 1, mirrors);
    }
    /**
    Add all the step maps in a given mapping to this one (preserving
    mirroring information).
    */
    appendMapping(mapping) {
      for (let i = mapping.from, startSize = this._maps.length; i < mapping.to; i++) {
        let mirr = mapping.getMirror(i);
        if (mirr != null)
          mirr = mirr < i && mirr >= mapping.from ? startSize + (mirr - mapping.from) : void 0;
        this.appendMap(mapping._maps[i], mirr);
      }
    }
    /**
    Finds the offset of the step map that mirrors the map at the
    given offset, in this mapping (as per the second argument to
    `appendMap`).
    */
    getMirror(n) {
      if (this.mirror) {
        for (let i = 0; i < this.mirror.length; i++)
          if (this.mirror[i] == n)
            return this.mirror[i + (i % 2 ? -1 : 1)];
      }
    }
    /**
    @internal
    */
    setMirror(n, m) {
      if (!this.mirror)
        this.mirror = [];
      this.mirror.push(n, m);
    }
    /**
    Append the inverse of the given mapping to this one.
    */
    appendMappingInverted(mapping) {
      for (let i = mapping.to - 1, totalSize = this._maps.length + mapping._maps.length; i >= mapping.from; i--) {
        let mirr = mapping.getMirror(i);
        if (mirr != null)
          mirr = mirr > i && mirr < mapping.to ? totalSize - (mirr - mapping.from) - 1 : void 0;
        this.appendMap(mapping._maps[i].invert(), mirr);
      }
    }
    /**
    Create an inverted version of this mapping.
    */
    invert() {
      let inverse = new _Mapping();
      inverse.appendMappingInverted(this);
      return inverse;
    }
    /**
    Map a position through this mapping.
    */
    map(pos, assoc = 1) {
      if (this.mirror)
        return this._map(pos, assoc, true);
      for (let i = this.from; i < this.to; i++)
        pos = this._maps[i].map(pos, assoc);
      return pos;
    }
    /**
    Map a position through this mapping, returning a mapping
    result.
    */
    mapResult(pos, assoc = 1) {
      return this._map(pos, assoc, false);
    }
    /**
    @internal
    */
    _map(pos, assoc, simple) {
      let delInfo = 0;
      for (let i = this.from; i < this.to; i++) {
        let map2 = this._maps[i], result = map2.mapResult(pos, assoc);
        if (result.recover != null) {
          let corr = this.getMirror(i);
          if (corr != null && corr > i && corr < this.to) {
            i = corr;
            pos = this._maps[corr].recover(result.recover);
            continue;
          }
        }
        delInfo |= result.delInfo;
        pos = result.pos;
      }
      return simple ? pos : new MapResult(pos, delInfo, null);
    }
  };
  var stepsByID = /* @__PURE__ */ Object.create(null);
  var Step = class {
    /**
    Get the step map that represents the changes made by this step,
    and which can be used to transform between positions in the old
    and the new document.
    */
    getMap() {
      return StepMap.empty;
    }
    /**
    Try to merge this step with another one, to be applied directly
    after it. Returns the merged step when possible, null if the
    steps can't be merged.
    */
    merge(other) {
      return null;
    }
    /**
    Deserialize a step from its JSON representation. Will call
    through to the step class' own implementation of this method.
    */
    static fromJSON(schema2, json) {
      if (!json || !json.stepType)
        throw new RangeError("Invalid input for Step.fromJSON");
      let type = stepsByID[json.stepType];
      if (!type)
        throw new RangeError(`No step type ${json.stepType} defined`);
      return type.fromJSON(schema2, json);
    }
    /**
    To be able to serialize steps to JSON, each step needs a string
    ID to attach to its JSON representation. Use this method to
    register an ID for your step classes. Try to pick something
    that's unlikely to clash with steps from other modules.
    */
    static jsonID(id, stepClass) {
      if (id in stepsByID)
        throw new RangeError("Duplicate use of step JSON ID " + id);
      stepsByID[id] = stepClass;
      stepClass.prototype.jsonID = id;
      return stepClass;
    }
  };
  var StepResult = class _StepResult {
    /**
    @internal
    */
    constructor(doc3, failed) {
      this.doc = doc3;
      this.failed = failed;
    }
    /**
    Create a successful step result.
    */
    static ok(doc3) {
      return new _StepResult(doc3, null);
    }
    /**
    Create a failed step result.
    */
    static fail(message) {
      return new _StepResult(null, message);
    }
    /**
    Call [`Node.replace`](https://prosemirror.net/docs/ref/#model.Node.replace) with the given
    arguments. Create a successful result if it succeeds, and a
    failed one if it throws a `ReplaceError`.
    */
    static fromReplace(doc3, from2, to, slice2) {
      try {
        return _StepResult.ok(doc3.replace(from2, to, slice2));
      } catch (e) {
        if (e instanceof ReplaceError)
          return _StepResult.fail(e.message);
        throw e;
      }
    }
  };
  function mapFragment(fragment, f, parent) {
    let mapped = [];
    for (let i = 0; i < fragment.childCount; i++) {
      let child = fragment.child(i);
      if (child.content.size)
        child = child.copy(mapFragment(child.content, f, child));
      if (child.isInline)
        child = f(child, parent, i);
      mapped.push(child);
    }
    return Fragment.fromArray(mapped);
  }
  var AddMarkStep = class _AddMarkStep extends Step {
    /**
    Create a mark step.
    */
    constructor(from2, to, mark) {
      super();
      this.from = from2;
      this.to = to;
      this.mark = mark;
    }
    apply(doc3) {
      let oldSlice = doc3.slice(this.from, this.to), $from = doc3.resolve(this.from);
      let parent = $from.node($from.sharedDepth(this.to));
      let slice2 = new Slice(mapFragment(oldSlice.content, (node, parent2) => {
        if (!node.isAtom || !parent2.type.allowsMarkType(this.mark.type))
          return node;
        return node.mark(this.mark.addToSet(node.marks));
      }, parent), oldSlice.openStart, oldSlice.openEnd);
      return StepResult.fromReplace(doc3, this.from, this.to, slice2);
    }
    invert(doc3) {
      let steps = [];
      doc3.nodesBetween(this.from, this.to, (node, pos) => {
        if (node.isInline && node.isAtom) {
          let added = this.mark.addToSet(node.marks);
          if (!Mark.sameSet(added, node.marks)) {
            let from2 = Math.max(this.from, pos), to = Math.min(this.to, pos + node.nodeSize);
            pushMarkStep(RemoveMarkStep, from2, to, this.mark, steps);
            for (let mark of node.marks)
              if (!mark.isInSet(added))
                pushMarkStep(_AddMarkStep, from2, to, mark, steps);
          }
        }
      });
      return steps.length == 1 ? steps[0] : new MarkSetStep(steps);
    }
    map(mapping) {
      let from2 = mapping.map(this.from, 1), to = mapping.map(this.to, -1);
      if (from2 >= to)
        return null;
      return new _AddMarkStep(from2, to, this.mark);
    }
    merge(other) {
      if (other instanceof _AddMarkStep && other.mark.eq(this.mark) && this.from <= other.to && this.to >= other.from)
        return new _AddMarkStep(Math.min(this.from, other.from), Math.max(this.to, other.to), this.mark);
      return null;
    }
    toJSON() {
      return {
        stepType: "addMark",
        mark: this.mark.toJSON(),
        from: this.from,
        to: this.to
      };
    }
    /**
    @internal
    */
    static fromJSON(schema2, json) {
      if (typeof json.from != "number" || typeof json.to != "number")
        throw new RangeError("Invalid input for AddMarkStep.fromJSON");
      return new _AddMarkStep(json.from, json.to, schema2.markFromJSON(json.mark));
    }
  };
  Step.jsonID("addMark", AddMarkStep);
  var RemoveMarkStep = class _RemoveMarkStep extends Step {
    /**
    Create a mark-removing step.
    */
    constructor(from2, to, mark) {
      super();
      this.from = from2;
      this.to = to;
      this.mark = mark;
    }
    apply(doc3) {
      let oldSlice = doc3.slice(this.from, this.to);
      let slice2 = new Slice(mapFragment(oldSlice.content, (node) => {
        return node.mark(this.mark.removeFromSet(node.marks));
      }, doc3), oldSlice.openStart, oldSlice.openEnd);
      return StepResult.fromReplace(doc3, this.from, this.to, slice2);
    }
    invert(doc3) {
      let steps = [];
      doc3.nodesBetween(this.from, this.to, (node, pos) => {
        if (node.isInline && node.isAtom && this.mark.isInSet(node.marks))
          pushMarkStep(AddMarkStep, Math.max(this.from, pos), Math.min(this.to, pos + node.nodeSize), this.mark, steps);
      });
      return steps.length == 1 ? steps[0] : new MarkSetStep(steps);
    }
    map(mapping) {
      let from2 = mapping.map(this.from, 1), to = mapping.map(this.to, -1);
      if (from2 >= to)
        return null;
      return new _RemoveMarkStep(from2, to, this.mark);
    }
    merge(other) {
      if (other instanceof _RemoveMarkStep && other.mark.eq(this.mark) && this.from <= other.to && this.to >= other.from)
        return new _RemoveMarkStep(Math.min(this.from, other.from), Math.max(this.to, other.to), this.mark);
      return null;
    }
    toJSON() {
      return {
        stepType: "removeMark",
        mark: this.mark.toJSON(),
        from: this.from,
        to: this.to
      };
    }
    /**
    @internal
    */
    static fromJSON(schema2, json) {
      if (typeof json.from != "number" || typeof json.to != "number")
        throw new RangeError("Invalid input for RemoveMarkStep.fromJSON");
      return new _RemoveMarkStep(json.from, json.to, schema2.markFromJSON(json.mark));
    }
  };
  Step.jsonID("removeMark", RemoveMarkStep);
  function pushMarkStep(cls, from2, to, mark, target) {
    let last = target.length ? target[target.length - 1] : null;
    if (last && last instanceof cls && last.to == from2 && last.mark.eq(mark)) {
      target[target.length - 1] = new cls(last.from, to, mark);
    } else {
      target.push(new cls(from2, to, mark));
    }
  }
  var MarkSetStep = class _MarkSetStep extends Step {
    constructor(steps) {
      super();
      this.steps = steps;
    }
    apply(doc3) {
      for (let step of this.steps) {
        let result = step.apply(doc3);
        if (!result.doc)
          return result;
        doc3 = result.doc;
      }
      return new StepResult(doc3, null);
    }
    invert(doc3) {
      return new _MarkSetStep(this.steps.map((s) => s.invert(doc3)));
    }
    map(mapping) {
      let result = [];
      for (let step of this.steps) {
        let mapped = step.map(mapping);
        if (mapped)
          result.push(mapped);
      }
      return result.length ? new _MarkSetStep(result) : null;
    }
    toJSON() {
      return { stepType: "markSet", steps: this.steps.map((s) => s.toJSON()) };
    }
    static fromJSON(schema2, json) {
      if (!Array.isArray(json.steps) || !json.steps.every((s) => s.stepType == "addMark" || s.stepType == "removeMark"))
        throw new RangeError("Invalid JSON for MarkSetStep");
      return new _MarkSetStep(json.steps.map((s) => Step.fromJSON(schema2, s)));
    }
  };
  Step.jsonID("markSet", MarkSetStep);
  var AddNodeMarkStep = class _AddNodeMarkStep extends Step {
    /**
    Create a node mark step.
    */
    constructor(pos, mark) {
      super();
      this.pos = pos;
      this.mark = mark;
    }
    apply(doc3) {
      let node = doc3.nodeAt(this.pos);
      if (!node)
        return StepResult.fail("No node at mark step's position");
      let updated = node.type.create(node.attrs, null, this.mark.addToSet(node.marks));
      return StepResult.fromReplace(doc3, this.pos, this.pos + 1, new Slice(Fragment.from(updated), 0, node.isLeaf ? 0 : 1));
    }
    invert(doc3) {
      let node = doc3.nodeAt(this.pos);
      if (node) {
        let newSet = this.mark.addToSet(node.marks);
        if (newSet.length == node.marks.length) {
          for (let i = 0; i < node.marks.length; i++)
            if (!node.marks[i].isInSet(newSet))
              return new _AddNodeMarkStep(this.pos, node.marks[i]);
          return new _AddNodeMarkStep(this.pos, this.mark);
        }
      }
      return new RemoveNodeMarkStep(this.pos, this.mark);
    }
    map(mapping) {
      let pos = mapping.mapResult(this.pos, 1);
      return pos.deletedAfter ? null : new _AddNodeMarkStep(pos.pos, this.mark);
    }
    toJSON() {
      return { stepType: "addNodeMark", pos: this.pos, mark: this.mark.toJSON() };
    }
    /**
    @internal
    */
    static fromJSON(schema2, json) {
      if (typeof json.pos != "number")
        throw new RangeError("Invalid input for AddNodeMarkStep.fromJSON");
      return new _AddNodeMarkStep(json.pos, schema2.markFromJSON(json.mark));
    }
  };
  Step.jsonID("addNodeMark", AddNodeMarkStep);
  var RemoveNodeMarkStep = class _RemoveNodeMarkStep extends Step {
    /**
    Create a mark-removing step.
    */
    constructor(pos, mark) {
      super();
      this.pos = pos;
      this.mark = mark;
    }
    apply(doc3) {
      let node = doc3.nodeAt(this.pos);
      if (!node)
        return StepResult.fail("No node at mark step's position");
      let updated = node.type.create(node.attrs, null, this.mark.removeFromSet(node.marks));
      return StepResult.fromReplace(doc3, this.pos, this.pos + 1, new Slice(Fragment.from(updated), 0, node.isLeaf ? 0 : 1));
    }
    invert(doc3) {
      let node = doc3.nodeAt(this.pos);
      if (!node || !this.mark.isInSet(node.marks))
        return this;
      return new AddNodeMarkStep(this.pos, this.mark);
    }
    map(mapping) {
      let pos = mapping.mapResult(this.pos, 1);
      return pos.deletedAfter ? null : new _RemoveNodeMarkStep(pos.pos, this.mark);
    }
    toJSON() {
      return { stepType: "removeNodeMark", pos: this.pos, mark: this.mark.toJSON() };
    }
    /**
    @internal
    */
    static fromJSON(schema2, json) {
      if (typeof json.pos != "number")
        throw new RangeError("Invalid input for RemoveNodeMarkStep.fromJSON");
      return new _RemoveNodeMarkStep(json.pos, schema2.markFromJSON(json.mark));
    }
  };
  Step.jsonID("removeNodeMark", RemoveNodeMarkStep);
  var ReplaceStep = class _ReplaceStep extends Step {
    /**
    The given `slice` should fit the 'gap' between `from` and
    `to`—the depths must line up, and the surrounding nodes must be
    able to be joined with the open sides of the slice. When
    `structure` is true, the step will fail if the content between
    from and to is not just a sequence of closing and then opening
    tokens (this is to guard against rebased replace steps
    overwriting something they weren't supposed to).
    */
    constructor(from2, to, slice2, structure = false) {
      super();
      this.from = from2;
      this.to = to;
      this.slice = slice2;
      this.structure = structure;
    }
    apply(doc3) {
      if (this.structure && contentBetween(doc3, this.from, this.to))
        return StepResult.fail("Structure replace would overwrite content");
      return StepResult.fromReplace(doc3, this.from, this.to, this.slice);
    }
    getMap() {
      return new StepMap([this.from, this.to - this.from, this.slice.size]);
    }
    invert(doc3) {
      return new _ReplaceStep(this.from, this.from + this.slice.size, doc3.slice(this.from, this.to));
    }
    map(mapping) {
      let to = mapping.mapResult(this.to, -1);
      let from2 = this.from == this.to && _ReplaceStep.MAP_BIAS < 0 ? to : mapping.mapResult(this.from, 1);
      if (from2.deletedAcross && to.deletedAcross)
        return null;
      return new _ReplaceStep(from2.pos, Math.max(from2.pos, to.pos), this.slice, this.structure);
    }
    merge(other) {
      if (!(other instanceof _ReplaceStep) || other.structure || this.structure)
        return null;
      if (this.from + this.slice.size == other.from && !this.slice.openEnd && !other.slice.openStart) {
        let slice2 = this.slice.size + other.slice.size == 0 ? Slice.empty : new Slice(this.slice.content.append(other.slice.content), this.slice.openStart, other.slice.openEnd);
        return new _ReplaceStep(this.from, this.to + (other.to - other.from), slice2, this.structure);
      } else if (other.to == this.from && !this.slice.openStart && !other.slice.openEnd) {
        let slice2 = this.slice.size + other.slice.size == 0 ? Slice.empty : new Slice(other.slice.content.append(this.slice.content), other.slice.openStart, this.slice.openEnd);
        return new _ReplaceStep(other.from, this.to, slice2, this.structure);
      } else {
        return null;
      }
    }
    toJSON() {
      let json = { stepType: "replace", from: this.from, to: this.to };
      if (this.slice.size)
        json.slice = this.slice.toJSON();
      if (this.structure)
        json.structure = true;
      return json;
    }
    /**
    @internal
    */
    static fromJSON(schema2, json) {
      if (typeof json.from != "number" || typeof json.to != "number")
        throw new RangeError("Invalid input for ReplaceStep.fromJSON");
      return new _ReplaceStep(json.from, json.to, Slice.fromJSON(schema2, json.slice), !!json.structure);
    }
  };
  ReplaceStep.MAP_BIAS = 1;
  Step.jsonID("replace", ReplaceStep);
  var ReplaceAroundStep = class _ReplaceAroundStep extends Step {
    /**
    Create a replace-around step with the given range and gap.
    `insert` should be the point in the slice into which the content
    of the gap should be moved. `structure` has the same meaning as
    it has in the [`ReplaceStep`](https://prosemirror.net/docs/ref/#transform.ReplaceStep) class.
    */
    constructor(from2, to, gapFrom, gapTo, slice2, insert, structure = false) {
      super();
      this.from = from2;
      this.to = to;
      this.gapFrom = gapFrom;
      this.gapTo = gapTo;
      this.slice = slice2;
      this.insert = insert;
      this.structure = structure;
    }
    apply(doc3) {
      if (this.structure && (contentBetween(doc3, this.from, this.gapFrom) || contentBetween(doc3, this.gapTo, this.to)))
        return StepResult.fail("Structure gap-replace would overwrite content");
      let gap = doc3.slice(this.gapFrom, this.gapTo);
      if (gap.openStart || gap.openEnd)
        return StepResult.fail("Gap is not a flat range");
      let inserted = this.slice.insertAt(this.insert, gap.content);
      if (!inserted)
        return StepResult.fail("Content does not fit in gap");
      return StepResult.fromReplace(doc3, this.from, this.to, inserted);
    }
    getMap() {
      return new StepMap([
        this.from,
        this.gapFrom - this.from,
        this.insert,
        this.gapTo,
        this.to - this.gapTo,
        this.slice.size - this.insert
      ]);
    }
    invert(doc3) {
      let gap = this.gapTo - this.gapFrom;
      return new _ReplaceAroundStep(this.from, this.from + this.slice.size + gap, this.from + this.insert, this.from + this.insert + gap, doc3.slice(this.from, this.to).removeBetween(this.gapFrom - this.from, this.gapTo - this.from), this.gapFrom - this.from, this.structure);
    }
    map(mapping) {
      let from2 = mapping.mapResult(this.from, 1), to = mapping.mapResult(this.to, -1);
      let gapFrom = this.from == this.gapFrom ? from2.pos : mapping.map(this.gapFrom, -1);
      let gapTo = this.to == this.gapTo ? to.pos : mapping.map(this.gapTo, 1);
      if (from2.deletedAcross && to.deletedAcross || gapFrom < from2.pos || gapTo > to.pos || gapFrom > gapTo)
        return null;
      return new _ReplaceAroundStep(from2.pos, to.pos, gapFrom, gapTo, this.slice, this.insert, this.structure);
    }
    toJSON() {
      let json = {
        stepType: "replaceAround",
        from: this.from,
        to: this.to,
        gapFrom: this.gapFrom,
        gapTo: this.gapTo,
        insert: this.insert
      };
      if (this.slice.size)
        json.slice = this.slice.toJSON();
      if (this.structure)
        json.structure = true;
      return json;
    }
    /**
    @internal
    */
    static fromJSON(schema2, json) {
      if (typeof json.from != "number" || typeof json.to != "number" || typeof json.gapFrom != "number" || typeof json.gapTo != "number" || typeof json.insert != "number")
        throw new RangeError("Invalid input for ReplaceAroundStep.fromJSON");
      return new _ReplaceAroundStep(json.from, json.to, json.gapFrom, json.gapTo, Slice.fromJSON(schema2, json.slice), json.insert, !!json.structure);
    }
  };
  Step.jsonID("replaceAround", ReplaceAroundStep);
  function contentBetween(doc3, from2, to) {
    let $from = doc3.resolve(from2), dist = to - from2, depth = $from.depth;
    while (dist > 0 && depth > 0 && $from.indexAfter(depth) == $from.node(depth).childCount) {
      depth--;
      dist--;
    }
    if (dist > 0) {
      let next = $from.node(depth).maybeChild($from.indexAfter(depth));
      while (dist > 0) {
        if (!next || next.isLeaf)
          return true;
        next = next.firstChild;
        dist--;
      }
    }
    return false;
  }
  function addMark(tr, from2, to, mark) {
    let added = [];
    tr.doc.nodesBetween(from2, to, (node, pos, parent) => {
      if (!node.isInline)
        return;
      let marks2 = node.marks;
      if (!mark.isInSet(marks2) && parent.type.allowsMarkType(mark.type)) {
        let start = Math.max(pos, from2), end = Math.min(pos + node.nodeSize, to);
        pushMarkStep(AddMarkStep, start, end, mark, added);
      }
    });
    added.forEach((s) => tr.step(s));
  }
  function removeMark(tr, from2, to, mark) {
    let matched = [], step = 0;
    tr.doc.nodesBetween(from2, to, (node, pos) => {
      if (!node.isInline || !node.isAtom)
        return;
      step++;
      let toRemove = null;
      if (mark instanceof MarkType) {
        let set = node.marks, found2;
        while (found2 = mark.isInSet(set)) {
          (toRemove || (toRemove = [])).push(found2);
          set = found2.removeFromSet(set);
        }
      } else if (mark) {
        if (mark.isInSet(node.marks))
          toRemove = [mark];
      } else {
        toRemove = node.marks;
      }
      if (toRemove && toRemove.length) {
        let end = Math.min(pos + node.nodeSize, to);
        for (let i = 0; i < toRemove.length; i++) {
          let style = toRemove[i], found2;
          for (let j = 0; j < matched.length; j++) {
            let m = matched[j];
            if (m.step == step - 1 && style.eq(matched[j].style))
              found2 = m;
          }
          if (found2) {
            found2.to = end;
            found2.step = step;
          } else {
            matched.push({ style, from: Math.max(pos, from2), to: end, step });
          }
        }
      }
    });
    matched.forEach((m) => tr.step(new RemoveMarkStep(m.from, m.to, m.style)));
  }
  function clearIncompatible(tr, pos, parentType, match = parentType.contentMatch, clearNewlines = true) {
    let node = tr.doc.nodeAt(pos);
    let replSteps = [], cur = pos + 1;
    for (let i = 0; i < node.childCount; i++) {
      let child = node.child(i), end = cur + child.nodeSize;
      let allowed = match.matchType(child.type);
      if (!allowed) {
        replSteps.push(new ReplaceStep(cur, end, Slice.empty));
      } else {
        match = allowed;
        for (let j = 0; j < child.marks.length; j++)
          if (!parentType.allowsMarkType(child.marks[j].type))
            tr.step(new RemoveMarkStep(cur, end, child.marks[j]));
        if (clearNewlines && child.isText && parentType.whitespace != "pre") {
          let m, newline = /\r?\n|\r/g, slice2;
          while (m = newline.exec(child.text)) {
            if (!slice2)
              slice2 = new Slice(Fragment.from(parentType.schema.text(" ", parentType.allowedMarks(child.marks))), 0, 0);
            replSteps.push(new ReplaceStep(cur + m.index, cur + m.index + m[0].length, slice2));
          }
        }
      }
      cur = end;
    }
    if (!match.validEnd) {
      let fill = match.fillBefore(Fragment.empty, true);
      tr.replace(cur, cur, new Slice(fill, 0, 0));
    }
    for (let i = replSteps.length - 1; i >= 0; i--)
      tr.step(replSteps[i]);
  }
  function canCut(node, start, end) {
    return (start == 0 || node.canReplace(start, node.childCount)) && (end == node.childCount || node.canReplace(0, end));
  }
  function liftTarget(range) {
    let parent = range.parent;
    let content = parent.content.cutByIndex(range.startIndex, range.endIndex);
    for (let depth = range.depth, contentBefore = 0, contentAfter = 0; ; --depth) {
      let node = range.$from.node(depth);
      let index = range.$from.index(depth) + contentBefore, endIndex = range.$to.indexAfter(depth) - contentAfter;
      if (depth < range.depth && node.canReplace(index, endIndex, content))
        return depth;
      if (depth == 0 || node.type.spec.isolating || !canCut(node, index, endIndex))
        break;
      if (index)
        contentBefore = 1;
      if (endIndex < node.childCount)
        contentAfter = 1;
    }
    return null;
  }
  function lift(tr, range, target) {
    let { $from, $to, depth } = range;
    let gapStart = $from.before(depth + 1), gapEnd = $to.after(depth + 1);
    let start = gapStart, end = gapEnd;
    let before = Fragment.empty, openStart = 0;
    for (let d = depth, splitting = false; d > target; d--)
      if (splitting || $from.index(d) > 0) {
        splitting = true;
        before = Fragment.from($from.node(d).copy(before));
        openStart++;
      } else {
        start--;
      }
    let after = Fragment.empty, openEnd = 0;
    for (let d = depth, splitting = false; d > target; d--)
      if (splitting || $to.after(d + 1) < $to.end(d)) {
        splitting = true;
        after = Fragment.from($to.node(d).copy(after));
        openEnd++;
      } else {
        end++;
      }
    tr.step(new ReplaceAroundStep(start, end, gapStart, gapEnd, new Slice(before.append(after), openStart, openEnd), before.size - openStart, true));
  }
  function findWrapping(range, nodeType, attrs = null, innerRange = range) {
    let around = findWrappingOutside(range, nodeType);
    let inner = around && findWrappingInside(innerRange, nodeType);
    if (!inner)
      return null;
    return around.map(withAttrs).concat({ type: nodeType, attrs }).concat(inner.map(withAttrs));
  }
  function withAttrs(type) {
    return { type, attrs: null };
  }
  function findWrappingOutside(range, type) {
    let { parent, startIndex, endIndex } = range;
    let around = parent.contentMatchAt(startIndex).findWrapping(type);
    if (!around)
      return null;
    let outer = around.length ? around[0] : type;
    return parent.canReplaceWith(startIndex, endIndex, outer) ? around : null;
  }
  function findWrappingInside(range, type) {
    let { parent, startIndex, endIndex } = range;
    let inner = parent.child(startIndex);
    let inside = type.contentMatch.findWrapping(inner.type);
    if (!inside)
      return null;
    let lastType = inside.length ? inside[inside.length - 1] : type;
    let innerMatch = lastType.contentMatch;
    for (let i = startIndex; innerMatch && i < endIndex; i++)
      innerMatch = innerMatch.matchType(parent.child(i).type);
    if (!innerMatch || !innerMatch.validEnd)
      return null;
    return inside;
  }
  function wrap(tr, range, wrappers) {
    let content = Fragment.empty;
    for (let i = wrappers.length - 1; i >= 0; i--) {
      if (content.size) {
        let match = wrappers[i].type.contentMatch.matchFragment(content);
        if (!match || !match.validEnd)
          throw new RangeError("Wrapper type given to Transform.wrap does not form valid content of its parent wrapper");
      }
      content = Fragment.from(wrappers[i].type.create(wrappers[i].attrs, content));
    }
    let start = range.start, end = range.end;
    tr.step(new ReplaceAroundStep(start, end, start, end, new Slice(content, 0, 0), wrappers.length, true));
  }
  function setBlockType(tr, from2, to, type, attrs) {
    if (!type.isTextblock)
      throw new RangeError("Type given to setBlockType should be a textblock");
    let mapFrom = tr.steps.length;
    tr.doc.nodesBetween(from2, to, (node, pos) => {
      let attrsHere = typeof attrs == "function" ? attrs(node) : attrs;
      if (node.isTextblock && !node.hasMarkup(type, attrsHere) && canChangeType(tr.doc, tr.mapping.slice(mapFrom).map(pos), type)) {
        let convertNewlines = null;
        if (type.schema.linebreakReplacement) {
          let pre = type.whitespace == "pre", supportLinebreak = !!type.contentMatch.matchType(type.schema.linebreakReplacement);
          if (pre && !supportLinebreak)
            convertNewlines = false;
          else if (!pre && supportLinebreak)
            convertNewlines = true;
        }
        if (convertNewlines === false)
          replaceLinebreaks(tr, node, pos, mapFrom);
        clearIncompatible(tr, tr.mapping.slice(mapFrom).map(pos, 1), type, void 0, convertNewlines === null);
        let mapping = tr.mapping.slice(mapFrom);
        let startM = mapping.map(pos, 1), endM = mapping.map(pos + node.nodeSize, 1);
        tr.step(new ReplaceAroundStep(startM, endM, startM + 1, endM - 1, new Slice(Fragment.from(type.create(attrsHere, null, node.marks)), 0, 0), 1, true));
        if (convertNewlines === true)
          replaceNewlines(tr, node, pos, mapFrom);
        return false;
      }
    });
  }
  function replaceNewlines(tr, node, pos, mapFrom) {
    node.forEach((child, offset) => {
      if (child.isText) {
        let m, newline = /\r?\n|\r/g;
        while (m = newline.exec(child.text)) {
          let start = tr.mapping.slice(mapFrom).map(pos + 1 + offset + m.index);
          tr.replaceWith(start, start + 1, node.type.schema.linebreakReplacement.create());
        }
      }
    });
  }
  function replaceLinebreaks(tr, node, pos, mapFrom) {
    node.forEach((child, offset) => {
      if (child.type == child.type.schema.linebreakReplacement) {
        let start = tr.mapping.slice(mapFrom).map(pos + 1 + offset);
        tr.replaceWith(start, start + 1, node.type.schema.text("\n"));
      }
    });
  }
  function canChangeType(doc3, pos, type) {
    let $pos = doc3.resolve(pos), index = $pos.index();
    return $pos.parent.canReplaceWith(index, index + 1, type);
  }
  function setNodeMarkup(tr, pos, type, attrs, marks2) {
    let node = tr.doc.nodeAt(pos);
    if (!node)
      throw new RangeError("No node at given position");
    if (!type)
      type = node.type;
    let newNode = type.create(attrs, null, marks2 || node.marks);
    if (node.isLeaf)
      return tr.replaceWith(pos, pos + node.nodeSize, newNode);
    if (!type.validContent(node.content))
      throw new RangeError("Invalid content for node type " + type.name);
    tr.step(new ReplaceAroundStep(pos, pos + node.nodeSize, pos + 1, pos + node.nodeSize - 1, new Slice(Fragment.from(newNode), 0, 0), 1, true));
  }
  function canSplit(doc3, pos, depth = 1, typesAfter) {
    let $pos = doc3.resolve(pos), base2 = $pos.depth - depth;
    let innerType = typesAfter && typesAfter[typesAfter.length - 1] || $pos.parent;
    if (base2 < 0 || $pos.parent.type.spec.isolating || !$pos.parent.canReplace($pos.index(), $pos.parent.childCount) || !innerType.type.validContent($pos.parent.content.cutByIndex($pos.index(), $pos.parent.childCount)))
      return false;
    for (let d = $pos.depth - 1, i = depth - 2; d > base2; d--, i--) {
      let node = $pos.node(d), index2 = $pos.index(d);
      if (node.type.spec.isolating)
        return false;
      let rest = node.content.cutByIndex(index2, node.childCount);
      let overrideChild = typesAfter && typesAfter[i + 1];
      if (overrideChild)
        rest = rest.replaceChild(0, overrideChild.type.create(overrideChild.attrs));
      let after = typesAfter && typesAfter[i] || node;
      if (!node.canReplace(index2 + 1, node.childCount) || !after.type.validContent(rest))
        return false;
    }
    let index = $pos.indexAfter(base2);
    let baseType = typesAfter && typesAfter[0];
    return $pos.node(base2).canReplaceWith(index, index, baseType ? baseType.type : $pos.node(base2 + 1).type);
  }
  function split(tr, pos, depth = 1, typesAfter) {
    let $pos = tr.doc.resolve(pos), before = Fragment.empty, after = Fragment.empty;
    for (let d = $pos.depth, e = $pos.depth - depth, i = depth - 1; d > e; d--, i--) {
      before = Fragment.from($pos.node(d).copy(before));
      let typeAfter = typesAfter && typesAfter[i];
      after = Fragment.from(typeAfter ? typeAfter.type.create(typeAfter.attrs, after) : $pos.node(d).copy(after));
    }
    tr.step(new ReplaceStep(pos, pos, new Slice(before.append(after), depth, depth), true));
  }
  function canJoin(doc3, pos) {
    let $pos = doc3.resolve(pos), index = $pos.index();
    return joinable2($pos.nodeBefore, $pos.nodeAfter) && $pos.parent.canReplace(index, index + 1);
  }
  function canAppendWithSubstitutedLinebreaks(a, b) {
    if (!b.content.size)
      a.type.compatibleContent(b.type);
    let match = a.contentMatchAt(a.childCount);
    let { linebreakReplacement } = a.type.schema;
    for (let i = 0; i < b.childCount; i++) {
      let child = b.child(i);
      let type = child.type == linebreakReplacement ? a.type.schema.nodes.text : child.type;
      match = match.matchType(type);
      if (!match)
        return false;
      if (!a.type.allowsMarks(child.marks))
        return false;
    }
    return match.validEnd;
  }
  function joinable2(a, b) {
    return !!(a && b && !a.isLeaf && canAppendWithSubstitutedLinebreaks(a, b));
  }
  function join(tr, pos, depth) {
    let convertNewlines = null;
    let { linebreakReplacement } = tr.doc.type.schema;
    let $before = tr.doc.resolve(pos - depth), beforeType = $before.node().type;
    if (linebreakReplacement && beforeType.inlineContent) {
      let pre = beforeType.whitespace == "pre";
      let supportLinebreak = !!beforeType.contentMatch.matchType(linebreakReplacement);
      if (pre && !supportLinebreak)
        convertNewlines = false;
      else if (!pre && supportLinebreak)
        convertNewlines = true;
    }
    let mapFrom = tr.steps.length;
    if (convertNewlines === false) {
      let $after = tr.doc.resolve(pos + depth);
      replaceLinebreaks(tr, $after.node(), $after.before(), mapFrom);
    }
    if (beforeType.inlineContent)
      clearIncompatible(tr, pos + depth - 1, beforeType, $before.node().contentMatchAt($before.index()), convertNewlines == null);
    let mapping = tr.mapping.slice(mapFrom), start = mapping.map(pos - depth);
    tr.step(new ReplaceStep(start, mapping.map(pos + depth, -1), Slice.empty, true));
    if (convertNewlines === true) {
      let $full = tr.doc.resolve(start);
      replaceNewlines(tr, $full.node(), $full.before(), tr.steps.length);
    }
    return tr;
  }
  function insertPoint(doc3, pos, nodeType) {
    let $pos = doc3.resolve(pos);
    if ($pos.parent.canReplaceWith($pos.index(), $pos.index(), nodeType))
      return pos;
    if ($pos.parentOffset == 0)
      for (let d = $pos.depth - 1; d >= 0; d--) {
        let index = $pos.index(d);
        if ($pos.node(d).canReplaceWith(index, index, nodeType))
          return $pos.before(d + 1);
        if (index > 0)
          return null;
      }
    if ($pos.parentOffset == $pos.parent.content.size)
      for (let d = $pos.depth - 1; d >= 0; d--) {
        let index = $pos.indexAfter(d);
        if ($pos.node(d).canReplaceWith(index, index, nodeType))
          return $pos.after(d + 1);
        if (index < $pos.node(d).childCount)
          return null;
      }
    return null;
  }
  function dropPoint(doc3, pos, slice2) {
    let $pos = doc3.resolve(pos);
    if (!slice2.content.size)
      return pos;
    let content = slice2.content;
    for (let i = 0; i < slice2.openStart; i++)
      content = content.firstChild.content;
    for (let pass = 1; pass <= (slice2.openStart == 0 && slice2.size ? 2 : 1); pass++) {
      for (let d = $pos.depth; d >= 0; d--) {
        let bias = d == $pos.depth ? 0 : $pos.pos <= ($pos.start(d + 1) + $pos.end(d + 1)) / 2 ? -1 : 1;
        for (let attempt = 0; attempt < 2; attempt++) {
          if (attempt) {
            if (!bias)
              break;
            bias = -bias;
          }
          let insertPos = $pos.index(d) + (bias > 0 ? 1 : 0);
          let parent = $pos.node(d), fits2 = false;
          if (pass == 1) {
            fits2 = parent.canReplace(insertPos, insertPos, content);
          } else {
            let wrapping = parent.contentMatchAt(insertPos).findWrapping(content.firstChild.type);
            fits2 = wrapping && parent.canReplaceWith(insertPos, insertPos, wrapping[0]);
          }
          if (fits2)
            return bias == 0 ? $pos.pos : bias < 0 ? $pos.before(d + 1) : $pos.after(d + 1);
        }
      }
    }
    return null;
  }
  function replaceStep(doc3, from2, to = from2, slice2 = Slice.empty) {
    if (from2 == to && !slice2.size)
      return null;
    let $from = doc3.resolve(from2), $to = doc3.resolve(to);
    if (fitsTrivially($from, $to, slice2))
      return new ReplaceStep(from2, to, slice2);
    return new Fitter($from, $to, slice2).fit();
  }
  function fitsTrivially($from, $to, slice2) {
    return !slice2.openStart && !slice2.openEnd && $from.start() == $to.start() && $from.parent.canReplace($from.index(), $to.index(), slice2.content);
  }
  var Fitter = class {
    constructor($from, $to, unplaced) {
      this.$from = $from;
      this.$to = $to;
      this.unplaced = unplaced;
      this.frontier = [];
      this.placed = Fragment.empty;
      for (let i = 0; i <= $from.depth; i++) {
        let node = $from.node(i);
        this.frontier.push({
          type: node.type,
          match: node.contentMatchAt($from.indexAfter(i))
        });
      }
      for (let i = $from.depth; i > 0; i--)
        this.placed = Fragment.from($from.node(i).copy(this.placed));
    }
    get depth() {
      return this.frontier.length - 1;
    }
    fit() {
      while (this.unplaced.size) {
        let fit = this.findFittable();
        if (fit)
          this.placeNodes(fit);
        else
          this.openMore() || this.dropNode();
      }
      let moveInline = this.mustMoveInline(), placedSize = this.placed.size - this.depth - this.$from.depth;
      let $from = this.$from, $to = this.close(moveInline < 0 ? this.$to : $from.doc.resolve(moveInline));
      if (!$to)
        return null;
      let content = this.placed, openStart = $from.depth, openEnd = $to.depth;
      while (openStart && openEnd && content.childCount == 1) {
        content = content.firstChild.content;
        openStart--;
        openEnd--;
      }
      let slice2 = new Slice(content, openStart, openEnd);
      if (moveInline > -1)
        return new ReplaceAroundStep($from.pos, moveInline, this.$to.pos, this.$to.end(), slice2, placedSize);
      if (slice2.size || $from.pos != this.$to.pos)
        return new ReplaceStep($from.pos, $to.pos, slice2);
      return null;
    }
    // Find a position on the start spine of `this.unplaced` that has
    // content that can be moved somewhere on the frontier. Returns two
    // depths, one for the slice and one for the frontier.
    findFittable() {
      let startDepth = this.unplaced.openStart;
      for (let cur = this.unplaced.content, d = 0, openEnd = this.unplaced.openEnd; d < startDepth; d++) {
        let node = cur.firstChild;
        if (cur.childCount > 1)
          openEnd = 0;
        if (node.type.spec.isolating && openEnd <= d) {
          startDepth = d;
          break;
        }
        cur = node.content;
      }
      for (let pass = 1; pass <= 2; pass++) {
        for (let sliceDepth = pass == 1 ? startDepth : this.unplaced.openStart; sliceDepth >= 0; sliceDepth--) {
          let fragment, parent = null;
          if (sliceDepth) {
            parent = contentAt(this.unplaced.content, sliceDepth - 1).firstChild;
            fragment = parent.content;
          } else {
            fragment = this.unplaced.content;
          }
          let first = fragment.firstChild;
          for (let frontierDepth = this.depth; frontierDepth >= 0; frontierDepth--) {
            let { type, match } = this.frontier[frontierDepth], wrap2, inject = null;
            if (pass == 1 && (first ? match.matchType(first.type) || (inject = match.fillBefore(Fragment.from(first), false)) : parent && type.compatibleContent(parent.type)))
              return { sliceDepth, frontierDepth, parent, inject };
            else if (pass == 2 && first && (wrap2 = match.findWrapping(first.type)))
              return { sliceDepth, frontierDepth, parent, wrap: wrap2 };
            if (parent && match.matchType(parent.type))
              break;
          }
        }
      }
    }
    openMore() {
      let { content, openStart, openEnd } = this.unplaced;
      if (maxOpen(content, -1) <= openStart)
        return false;
      if (this.unplaced.size > 1 && maxOpen(content, 1) > openEnd)
        openEnd++;
      this.unplaced = new Slice(content, openStart + 1, openEnd);
      return true;
    }
    dropNode() {
      let { content, openStart, openEnd } = this.unplaced;
      let inner = contentAt(content, openStart);
      if (inner.childCount <= 1 && openStart > 0) {
        let openAtEnd = content.size - openStart <= openStart + inner.size;
        this.unplaced = new Slice(dropFromFragment(content, openStart - 1, 1), openStart - 1, openAtEnd ? openStart - 1 : openEnd);
      } else {
        this.unplaced = new Slice(dropFromFragment(content, openStart, 1), openStart, openEnd);
      }
    }
    // Move content from the unplaced slice at `sliceDepth` to the
    // frontier node at `frontierDepth`. Close that frontier node when
    // applicable.
    placeNodes({ sliceDepth, frontierDepth, parent, inject, wrap: wrap2 }) {
      while (this.depth > frontierDepth)
        this.closeFrontierNode();
      if (wrap2)
        for (let i = 0; i < wrap2.length; i++)
          this.openFrontierNode(wrap2[i]);
      let slice2 = this.unplaced, fragment = parent ? parent.content : slice2.content;
      let openStart = slice2.openStart - sliceDepth;
      let taken = 0, add = [];
      let { match, type } = this.frontier[frontierDepth];
      if (inject) {
        for (let i = 0; i < inject.childCount; i++)
          add.push(inject.child(i));
        match = match.matchFragment(inject);
      }
      let openEndCount = fragment.size + sliceDepth - (slice2.content.size - slice2.openEnd);
      while (taken < fragment.childCount) {
        let next = fragment.child(taken), matches2 = match.matchType(next.type);
        if (!matches2)
          break;
        taken++;
        if (taken > 1 || openStart == 0 || next.content.size) {
          match = matches2;
          add.push(closeNodeStart(next.mark(type.allowedMarks(next.marks)), taken == 1 ? openStart : 0, taken == fragment.childCount ? openEndCount : -1));
        }
      }
      let toEnd = taken == fragment.childCount;
      if (!toEnd)
        openEndCount = -1;
      this.placed = addToFragment(this.placed, frontierDepth, Fragment.from(add));
      this.frontier[frontierDepth].match = match;
      if (toEnd && openEndCount < 0 && parent && parent.type == this.frontier[this.depth].type && this.frontier.length > 1)
        this.closeFrontierNode();
      for (let i = 0, cur = add[add.length - 1]; cur && i < openEndCount; i++) {
        this.frontier.push({ type: cur.type, match: cur.contentMatchAt(cur.childCount) });
        cur = cur.lastChild;
      }
      this.unplaced = !toEnd ? new Slice(dropFromFragment(slice2.content, sliceDepth, taken), sliceDepth, slice2.openEnd) : sliceDepth == 0 ? Slice.empty : new Slice(dropFromFragment(slice2.content, sliceDepth - 1, 1), sliceDepth - 1, openEndCount < 0 ? slice2.openEnd : sliceDepth - 1);
    }
    mustMoveInline() {
      if (!this.$to.parent.isTextblock)
        return -1;
      let top = this.frontier[this.depth], level;
      if (!top.type.isTextblock || !contentAfterFits(this.$to, this.$to.depth, top.type, top.match, false) || this.$to.depth == this.depth && (level = this.findCloseLevel(this.$to)) && level.depth == this.depth)
        return -1;
      let { depth } = this.$to, after = this.$to.after(depth);
      while (depth > 1 && after == this.$to.end(--depth))
        ++after;
      return after;
    }
    findCloseLevel($to) {
      scan: for (let i = Math.min(this.depth, $to.depth); i >= 0; i--) {
        let { match, type } = this.frontier[i];
        let dropInner = i < $to.depth && $to.end(i + 1) == $to.pos + ($to.depth - (i + 1));
        let fit = contentAfterFits($to, i, type, match, dropInner);
        if (!fit)
          continue;
        for (let d = i - 1; d >= 0; d--) {
          let { match: match2, type: type2 } = this.frontier[d];
          let matches2 = contentAfterFits($to, d, type2, match2, true);
          if (!matches2 || matches2.childCount)
            continue scan;
        }
        return { depth: i, fit, move: dropInner ? $to.doc.resolve($to.after(i + 1)) : $to };
      }
    }
    close($to) {
      let close2 = this.findCloseLevel($to);
      if (!close2)
        return null;
      while (this.depth > close2.depth)
        this.closeFrontierNode();
      if (close2.fit.childCount)
        this.placed = addToFragment(this.placed, close2.depth, close2.fit);
      $to = close2.move;
      for (let d = close2.depth + 1; d <= $to.depth; d++) {
        let node = $to.node(d), add = node.type.contentMatch.fillBefore(node.content, true, $to.index(d));
        this.openFrontierNode(node.type, node.attrs, add);
      }
      return $to;
    }
    openFrontierNode(type, attrs = null, content) {
      let top = this.frontier[this.depth];
      top.match = top.match.matchType(type);
      this.placed = addToFragment(this.placed, this.depth, Fragment.from(type.create(attrs, content)));
      this.frontier.push({ type, match: type.contentMatch });
    }
    closeFrontierNode() {
      let open = this.frontier.pop();
      let add = open.match.fillBefore(Fragment.empty, true);
      if (add.childCount)
        this.placed = addToFragment(this.placed, this.frontier.length, add);
    }
  };
  function dropFromFragment(fragment, depth, count) {
    if (depth == 0)
      return fragment.cutByIndex(count, fragment.childCount);
    return fragment.replaceChild(0, fragment.firstChild.copy(dropFromFragment(fragment.firstChild.content, depth - 1, count)));
  }
  function addToFragment(fragment, depth, content) {
    if (depth == 0)
      return fragment.append(content);
    return fragment.replaceChild(fragment.childCount - 1, fragment.lastChild.copy(addToFragment(fragment.lastChild.content, depth - 1, content)));
  }
  function contentAt(fragment, depth) {
    for (let i = 0; i < depth; i++)
      fragment = fragment.firstChild.content;
    return fragment;
  }
  function closeNodeStart(node, openStart, openEnd) {
    if (openStart <= 0)
      return node;
    let frag = node.content;
    if (openStart > 1)
      frag = frag.replaceChild(0, closeNodeStart(frag.firstChild, openStart - 1, frag.childCount == 1 ? openEnd - 1 : 0));
    if (openStart > 0) {
      frag = node.type.contentMatch.fillBefore(frag).append(frag);
      if (openEnd <= 0)
        frag = frag.append(node.type.contentMatch.matchFragment(frag).fillBefore(Fragment.empty, true));
    }
    return node.copy(frag);
  }
  function contentAfterFits($to, depth, type, match, open) {
    let node = $to.node(depth), index = open ? $to.indexAfter(depth) : $to.index(depth);
    if (index == node.childCount && !type.compatibleContent(node.type))
      return null;
    let fit = match.fillBefore(node.content, true, index);
    return fit && !invalidMarks(type, node.content, index) ? fit : null;
  }
  function invalidMarks(type, fragment, start) {
    for (let i = start; i < fragment.childCount; i++)
      if (!type.allowsMarks(fragment.child(i).marks))
        return true;
    return false;
  }
  function definesContent(type) {
    return type.spec.defining || type.spec.definingForContent;
  }
  function maxOpen(frag, side) {
    for (let count = 0; ; count++) {
      let ch = side < 0 ? frag.firstChild : frag.lastChild;
      if (!ch || ch.isAtom)
        return count;
      frag = ch.content;
    }
  }
  function replaceRange(tr, from2, to, slice2) {
    if (!slice2.size)
      return tr.deleteRange(from2, to);
    let $from = tr.doc.resolve(from2), $to = tr.doc.resolve(to);
    if (fitsTrivially($from, $to, slice2))
      return tr.step(new ReplaceStep(from2, to, slice2));
    let targetDepths = coveredDepths($from, $to);
    if (targetDepths[targetDepths.length - 1] == 0)
      targetDepths.pop();
    let preferredTarget = -($from.depth + 1);
    targetDepths.unshift(preferredTarget);
    for (let d = $from.depth, pos = $from.pos - 1; d > 0; d--, pos--) {
      let spec = $from.node(d).type.spec;
      if (spec.defining || spec.definingAsContext || spec.isolating)
        break;
      if (targetDepths.indexOf(d) > -1)
        preferredTarget = d;
      else if ($from.before(d) == pos)
        targetDepths.splice(1, 0, -d);
    }
    let preferredTargetIndex = targetDepths.indexOf(preferredTarget);
    let leftNodes = [], preferredDepth = slice2.openStart;
    for (let content = slice2.content, i = 0; ; i++) {
      let node = content.firstChild;
      leftNodes.push(node);
      if (i == slice2.openStart)
        break;
      content = node.content;
    }
    for (let d = preferredDepth - 1; d >= 0; d--) {
      let leftNode = leftNodes[d], def = definesContent(leftNode.type);
      if (def && !leftNode.sameMarkup($from.node(Math.abs(preferredTarget) - 1)))
        preferredDepth = d;
      else if (def || !leftNode.type.isTextblock)
        break;
    }
    for (let j = slice2.openStart; j >= 0; j--) {
      let openDepth = (j + preferredDepth + 1) % (slice2.openStart + 1);
      let insert = leftNodes[openDepth];
      if (!insert)
        continue;
      for (let i = 0; i < targetDepths.length; i++) {
        let targetDepth = targetDepths[(i + preferredTargetIndex) % targetDepths.length], expand = true;
        if (targetDepth < 0) {
          expand = false;
          targetDepth = -targetDepth;
        }
        let parent = $from.node(targetDepth - 1), index = $from.index(targetDepth - 1);
        if (parent.canReplaceWith(index, index, insert.type, insert.marks))
          return tr.replace($from.before(targetDepth), expand ? $to.after(targetDepth) : to, new Slice(closeFragment(slice2.content, 0, slice2.openStart, openDepth), openDepth, slice2.openEnd));
      }
    }
    let startSteps = tr.steps.length;
    for (let i = targetDepths.length - 1; i >= 0; i--) {
      tr.replace(from2, to, slice2);
      if (tr.steps.length > startSteps)
        break;
      let depth = targetDepths[i];
      if (depth < 0)
        continue;
      from2 = $from.before(depth);
      to = $to.after(depth);
    }
  }
  function closeFragment(fragment, depth, oldOpen, newOpen, parent) {
    if (depth < oldOpen) {
      let first = fragment.firstChild;
      fragment = fragment.replaceChild(0, first.copy(closeFragment(first.content, depth + 1, oldOpen, newOpen, first)));
    }
    if (depth > newOpen) {
      let match = parent.contentMatchAt(0);
      let start = match.fillBefore(fragment).append(fragment);
      fragment = start.append(match.matchFragment(start).fillBefore(Fragment.empty, true));
    }
    return fragment;
  }
  function replaceRangeWith(tr, from2, to, node) {
    if (!node.isInline && from2 == to && tr.doc.resolve(from2).parent.content.size) {
      let point = insertPoint(tr.doc, from2, node.type);
      if (point != null)
        from2 = to = point;
    }
    tr.replaceRange(from2, to, new Slice(Fragment.from(node), 0, 0));
  }
  function deleteRange(tr, from2, to) {
    let $from = tr.doc.resolve(from2), $to = tr.doc.resolve(to);
    if ($from.parent.isTextblock && $to.parent.isTextblock && $from.start() != $to.start() && $from.parentOffset == 0 && $to.parentOffset == 0) {
      let shared = $from.sharedDepth(to), isolated = false;
      for (let d = $from.depth; d > shared; d--)
        if ($from.node(d).type.spec.isolating)
          isolated = true;
      for (let d = $to.depth; d > shared; d--)
        if ($to.node(d).type.spec.isolating)
          isolated = true;
      if (!isolated) {
        for (let d = $from.depth; d > 0 && from2 == $from.start(d); d--)
          from2 = $from.before(d);
        for (let d = $to.depth; d > 0 && to == $to.start(d); d--)
          to = $to.before(d);
        $from = tr.doc.resolve(from2);
        $to = tr.doc.resolve(to);
      }
    }
    let covered = coveredDepths($from, $to);
    for (let i = 0; i < covered.length; i++) {
      let depth = covered[i], last = i == covered.length - 1;
      if (last && depth == 0 || $from.node(depth).type.contentMatch.validEnd)
        return tr.delete($from.start(depth), $to.end(depth));
      if (depth > 0 && (last || $from.node(depth - 1).canReplace($from.index(depth - 1), $to.indexAfter(depth - 1))))
        return tr.delete($from.before(depth), $to.after(depth));
    }
    for (let d = 1; d <= $from.depth && d <= $to.depth; d++) {
      if (from2 - $from.start(d) == $from.depth - d && to > $from.end(d) && $to.end(d) - to != $to.depth - d && $from.start(d - 1) == $to.start(d - 1) && $from.node(d - 1).canReplace($from.index(d - 1), $to.index(d - 1)))
        return tr.delete($from.before(d), to);
    }
    tr.delete(from2, to);
  }
  function coveredDepths($from, $to) {
    let result = [], minDepth = Math.min($from.depth, $to.depth);
    for (let d = minDepth; d >= 0; d--) {
      let start = $from.start(d);
      if (start < $from.pos - ($from.depth - d) || $to.end(d) > $to.pos + ($to.depth - d) || $from.node(d).type.spec.isolating || $to.node(d).type.spec.isolating)
        break;
      if (start == $to.start(d) || d == $from.depth && d == $to.depth && $from.parent.inlineContent && $to.parent.inlineContent && d && $to.start(d - 1) == start - 1)
        result.push(d);
    }
    return result;
  }
  var AttrStep = class _AttrStep extends Step {
    /**
    Construct an attribute step.
    */
    constructor(pos, attr, value) {
      super();
      this.pos = pos;
      this.attr = attr;
      this.value = value;
    }
    apply(doc3) {
      let node = doc3.nodeAt(this.pos);
      if (!node)
        return StepResult.fail("No node at attribute step's position");
      let attrs = /* @__PURE__ */ Object.create(null);
      for (let name in node.attrs)
        attrs[name] = node.attrs[name];
      attrs[this.attr] = this.value;
      let updated = node.type.create(attrs, null, node.marks);
      return StepResult.fromReplace(doc3, this.pos, this.pos + 1, new Slice(Fragment.from(updated), 0, node.isLeaf ? 0 : 1));
    }
    getMap() {
      return StepMap.empty;
    }
    invert(doc3) {
      return new _AttrStep(this.pos, this.attr, doc3.nodeAt(this.pos).attrs[this.attr]);
    }
    map(mapping) {
      let pos = mapping.mapResult(this.pos, 1);
      return pos.deletedAfter ? null : new _AttrStep(pos.pos, this.attr, this.value);
    }
    toJSON() {
      return { stepType: "attr", pos: this.pos, attr: this.attr, value: this.value };
    }
    static fromJSON(schema2, json) {
      if (typeof json.pos != "number" || typeof json.attr != "string")
        throw new RangeError("Invalid input for AttrStep.fromJSON");
      return new _AttrStep(json.pos, json.attr, json.value);
    }
  };
  Step.jsonID("attr", AttrStep);
  var DocAttrStep = class _DocAttrStep extends Step {
    /**
    Construct an attribute step.
    */
    constructor(attr, value) {
      super();
      this.attr = attr;
      this.value = value;
    }
    apply(doc3) {
      let attrs = /* @__PURE__ */ Object.create(null);
      for (let name in doc3.attrs)
        attrs[name] = doc3.attrs[name];
      attrs[this.attr] = this.value;
      let updated = doc3.type.create(attrs, doc3.content, doc3.marks);
      return StepResult.ok(updated);
    }
    getMap() {
      return StepMap.empty;
    }
    invert(doc3) {
      return new _DocAttrStep(this.attr, doc3.attrs[this.attr]);
    }
    map(mapping) {
      return this;
    }
    toJSON() {
      return { stepType: "docAttr", attr: this.attr, value: this.value };
    }
    static fromJSON(schema2, json) {
      if (typeof json.attr != "string")
        throw new RangeError("Invalid input for DocAttrStep.fromJSON");
      return new _DocAttrStep(json.attr, json.value);
    }
  };
  Step.jsonID("docAttr", DocAttrStep);
  var TransformError = class extends Error {
  };
  TransformError = function TransformError2(message) {
    let err = Error.call(this, message);
    err.__proto__ = TransformError2.prototype;
    return err;
  };
  TransformError.prototype = Object.create(Error.prototype);
  TransformError.prototype.constructor = TransformError;
  TransformError.prototype.name = "TransformError";
  var Transform = class {
    /**
    Create a transform that starts with the given document.
    */
    constructor(doc3) {
      this.doc = doc3;
      this.steps = [];
      this.docs = [];
      this.mapping = new Mapping();
    }
    /**
    The starting document.
    */
    get before() {
      return this.docs.length ? this.docs[0] : this.doc;
    }
    /**
    Apply a new step in this transform, saving the result. Throws an
    error when the step fails.
    */
    step(step) {
      let result = this.maybeStep(step);
      if (result.failed)
        throw new TransformError(result.failed);
      return this;
    }
    /**
    Try to apply a step in this transformation, ignoring it if it
    fails. Returns the step result.
    */
    maybeStep(step) {
      let result = step.apply(this.doc);
      if (!result.failed)
        this.addStep(step, result.doc);
      return result;
    }
    /**
    True when the document has been changed (when there are any
    steps).
    */
    get docChanged() {
      return this.steps.length > 0;
    }
    /**
    Return a single range, in post-transform document positions,
    that covers all content changed by this transform. Returns null
    if no replacements are made. Note that this will ignore changes
    that add/remove marks without replacing the underlying content.
    */
    changedRange() {
      let from2 = 1e9, to = -1e9;
      for (let i = 0; i < this.mapping.maps.length; i++) {
        let map2 = this.mapping.maps[i];
        if (i) {
          from2 = map2.map(from2, 1);
          to = map2.map(to, -1);
        }
        map2.forEach((_f, _t, fromB, toB) => {
          from2 = Math.min(from2, fromB);
          to = Math.max(to, toB);
        });
      }
      return from2 == 1e9 ? null : { from: from2, to };
    }
    /**
    @internal
    */
    addStep(step, doc3) {
      this.docs.push(this.doc);
      this.steps.push(step);
      this.mapping.appendMap(step.getMap());
      this.doc = doc3;
    }
    /**
    Replace the part of the document between `from` and `to` with the
    given `slice`.
    */
    replace(from2, to = from2, slice2 = Slice.empty) {
      let step = replaceStep(this.doc, from2, to, slice2);
      if (step)
        this.step(step);
      return this;
    }
    /**
    Replace the given range with the given content, which may be a
    fragment, node, or array of nodes.
    */
    replaceWith(from2, to, content) {
      return this.replace(from2, to, new Slice(Fragment.from(content), 0, 0));
    }
    /**
    Delete the content between the given positions.
    */
    delete(from2, to) {
      return this.replace(from2, to, Slice.empty);
    }
    /**
    Insert the given content at the given position.
    */
    insert(pos, content) {
      return this.replaceWith(pos, pos, content);
    }
    /**
    Replace a range of the document with a given slice, using
    `from`, `to`, and the slice's
    [`openStart`](https://prosemirror.net/docs/ref/#model.Slice.openStart) property as hints, rather
    than fixed start and end points. This method may grow the
    replaced area or close open nodes in the slice in order to get a
    fit that is more in line with WYSIWYG expectations, by dropping
    fully covered parent nodes of the replaced region when they are
    marked [non-defining as
    context](https://prosemirror.net/docs/ref/#model.NodeSpec.definingAsContext), or including an
    open parent node from the slice that _is_ marked as [defining
    its content](https://prosemirror.net/docs/ref/#model.NodeSpec.definingForContent).
    
    This is the method, for example, to handle paste. The similar
    [`replace`](https://prosemirror.net/docs/ref/#transform.Transform.replace) method is a more
    primitive tool which will _not_ move the start and end of its given
    range, and is useful in situations where you need more precise
    control over what happens.
    */
    replaceRange(from2, to, slice2) {
      replaceRange(this, from2, to, slice2);
      return this;
    }
    /**
    Replace the given range with a node, but use `from` and `to` as
    hints, rather than precise positions. When from and to are the same
    and are at the start or end of a parent node in which the given
    node doesn't fit, this method may _move_ them out towards a parent
    that does allow the given node to be placed. When the given range
    completely covers a parent node, this method may completely replace
    that parent node.
    */
    replaceRangeWith(from2, to, node) {
      replaceRangeWith(this, from2, to, node);
      return this;
    }
    /**
    Delete the given range, expanding it to cover fully covered
    parent nodes until a valid replace is found.
    */
    deleteRange(from2, to) {
      deleteRange(this, from2, to);
      return this;
    }
    /**
    Split the content in the given range off from its parent, if there
    is sibling content before or after it, and move it up the tree to
    the depth specified by `target`. You'll probably want to use
    [`liftTarget`](https://prosemirror.net/docs/ref/#transform.liftTarget) to compute `target`, to make
    sure the lift is valid.
    */
    lift(range, target) {
      lift(this, range, target);
      return this;
    }
    /**
    Join the blocks around the given position. If depth is 2, their
    last and first siblings are also joined, and so on.
    */
    join(pos, depth = 1) {
      join(this, pos, depth);
      return this;
    }
    /**
    Wrap the given [range](https://prosemirror.net/docs/ref/#model.NodeRange) in the given set of wrappers.
    The wrappers are assumed to be valid in this position, and should
    probably be computed with [`findWrapping`](https://prosemirror.net/docs/ref/#transform.findWrapping).
    */
    wrap(range, wrappers) {
      wrap(this, range, wrappers);
      return this;
    }
    /**
    Set the type of all textblocks (partly) between `from` and `to` to
    the given node type with the given attributes.
    */
    setBlockType(from2, to = from2, type, attrs = null) {
      setBlockType(this, from2, to, type, attrs);
      return this;
    }
    /**
    Change the type, attributes, and/or marks of the node at `pos`.
    When `type` isn't given, the existing node type is preserved,
    */
    setNodeMarkup(pos, type, attrs = null, marks2) {
      setNodeMarkup(this, pos, type, attrs, marks2);
      return this;
    }
    /**
    Set a single attribute on a given node to a new value.
    The `pos` addresses the document content. Use `setDocAttribute`
    to set attributes on the document itself.
    */
    setNodeAttribute(pos, attr, value) {
      this.step(new AttrStep(pos, attr, value));
      return this;
    }
    /**
    Set a single attribute on the document to a new value.
    */
    setDocAttribute(attr, value) {
      this.step(new DocAttrStep(attr, value));
      return this;
    }
    /**
    Add a mark to the node at position `pos`.
    */
    addNodeMark(pos, mark) {
      this.step(new AddNodeMarkStep(pos, mark));
      return this;
    }
    /**
    Remove a mark (or all marks of the given type) from the node at
    position `pos`.
    */
    removeNodeMark(pos, mark) {
      let node = this.doc.nodeAt(pos);
      if (!node)
        throw new RangeError("No node at position " + pos);
      if (mark instanceof Mark) {
        if (mark.isInSet(node.marks))
          this.step(new RemoveNodeMarkStep(pos, mark));
      } else {
        let set = node.marks, found2, steps = [];
        while (found2 = mark.isInSet(set)) {
          steps.push(new RemoveNodeMarkStep(pos, found2));
          set = found2.removeFromSet(set);
        }
        for (let i = steps.length - 1; i >= 0; i--)
          this.step(steps[i]);
      }
      return this;
    }
    /**
    Split the node at the given position, and optionally, if `depth` is
    greater than one, any number of nodes above that. By default, the
    parts split off will inherit the node type of the original node.
    This can be changed by passing an array of types and attributes to
    use after the split (with the outermost nodes coming first).
    */
    split(pos, depth = 1, typesAfter) {
      split(this, pos, depth, typesAfter);
      return this;
    }
    /**
    Add the given mark to the inline content between `from` and `to`.
    */
    addMark(from2, to, mark) {
      addMark(this, from2, to, mark);
      return this;
    }
    /**
    Remove marks from inline nodes between `from` and `to`. When
    `mark` is a single mark, remove precisely that mark. When it is
    a mark type, remove all marks of that type. When it is null,
    remove all marks of any type.
    */
    removeMark(from2, to, mark) {
      removeMark(this, from2, to, mark);
      return this;
    }
    /**
    Removes all marks and nodes from the content of the node at
    `pos` that don't match the given new parent node type. Accepts
    an optional starting [content match](https://prosemirror.net/docs/ref/#model.ContentMatch) as
    third argument.
    */
    clearIncompatible(pos, parentType, match) {
      clearIncompatible(this, pos, parentType, match);
      return this;
    }
  };

  // node_modules/prosemirror-state/dist/index.js
  var classesById = /* @__PURE__ */ Object.create(null);
  var Selection = class {
    /**
    Initialize a selection with the head and anchor and ranges. If no
    ranges are given, constructs a single range across `$anchor` and
    `$head`.
    */
    constructor($anchor, $head, ranges) {
      this.$anchor = $anchor;
      this.$head = $head;
      this.ranges = ranges || [new SelectionRange($anchor.min($head), $anchor.max($head))];
    }
    /**
    The selection's anchor, as an unresolved position.
    */
    get anchor() {
      return this.$anchor.pos;
    }
    /**
    The selection's head.
    */
    get head() {
      return this.$head.pos;
    }
    /**
    The lower bound of the selection's main range.
    */
    get from() {
      return this.$from.pos;
    }
    /**
    The upper bound of the selection's main range.
    */
    get to() {
      return this.$to.pos;
    }
    /**
    The resolved lower  bound of the selection's main range.
    */
    get $from() {
      return this.ranges[0].$from;
    }
    /**
    The resolved upper bound of the selection's main range.
    */
    get $to() {
      return this.ranges[0].$to;
    }
    /**
    Indicates whether the selection contains any content.
    */
    get empty() {
      let ranges = this.ranges;
      for (let i = 0; i < ranges.length; i++)
        if (ranges[i].$from.pos != ranges[i].$to.pos)
          return false;
      return true;
    }
    /**
    Get the content of this selection as a slice.
    */
    content() {
      return this.$from.doc.slice(this.from, this.to, true);
    }
    /**
    Replace the selection with a slice or, if no slice is given,
    delete the selection. Will append to the given transaction.
    */
    replace(tr, content = Slice.empty) {
      let lastNode = content.content.lastChild, lastParent = null;
      for (let i = 0; i < content.openEnd; i++) {
        lastParent = lastNode;
        lastNode = lastNode.lastChild;
      }
      let mapFrom = tr.steps.length, ranges = this.ranges;
      for (let i = 0; i < ranges.length; i++) {
        let { $from, $to } = ranges[i], mapping = tr.mapping.slice(mapFrom);
        tr.replaceRange(mapping.map($from.pos), mapping.map($to.pos), i ? Slice.empty : content);
        if (i == 0)
          selectionToInsertionEnd(tr, mapFrom, (lastNode ? lastNode.isInline : lastParent && lastParent.isTextblock) ? -1 : 1);
      }
    }
    /**
    Replace the selection with the given node, appending the changes
    to the given transaction.
    */
    replaceWith(tr, node) {
      let mapFrom = tr.steps.length, ranges = this.ranges;
      for (let i = 0; i < ranges.length; i++) {
        let { $from, $to } = ranges[i], mapping = tr.mapping.slice(mapFrom);
        let from2 = mapping.map($from.pos), to = mapping.map($to.pos);
        if (i) {
          tr.deleteRange(from2, to);
        } else {
          tr.replaceRangeWith(from2, to, node);
          selectionToInsertionEnd(tr, mapFrom, node.isInline ? -1 : 1);
        }
      }
    }
    /**
    Find a valid cursor or leaf node selection starting at the given
    position and searching back if `dir` is negative, and forward if
    positive. When `textOnly` is true, only consider cursor
    selections. Will return null when no valid selection position is
    found.
    */
    static findFrom($pos, dir, textOnly = false) {
      let inner = $pos.parent.inlineContent ? new TextSelection($pos) : findSelectionIn($pos.node(0), $pos.parent, $pos.pos, $pos.index(), dir, textOnly);
      if (inner)
        return inner;
      for (let depth = $pos.depth - 1; depth >= 0; depth--) {
        let found2 = dir < 0 ? findSelectionIn($pos.node(0), $pos.node(depth), $pos.before(depth + 1), $pos.index(depth), dir, textOnly) : findSelectionIn($pos.node(0), $pos.node(depth), $pos.after(depth + 1), $pos.index(depth) + 1, dir, textOnly);
        if (found2)
          return found2;
      }
      return null;
    }
    /**
    Find a valid cursor or leaf node selection near the given
    position. Searches forward first by default, but if `bias` is
    negative, it will search backwards first.
    */
    static near($pos, bias = 1) {
      return this.findFrom($pos, bias) || this.findFrom($pos, -bias) || new AllSelection($pos.node(0));
    }
    /**
    Find the cursor or leaf node selection closest to the start of
    the given document. Will return an
    [`AllSelection`](https://prosemirror.net/docs/ref/#state.AllSelection) if no valid position
    exists.
    */
    static atStart(doc3) {
      return findSelectionIn(doc3, doc3, 0, 0, 1) || new AllSelection(doc3);
    }
    /**
    Find the cursor or leaf node selection closest to the end of the
    given document.
    */
    static atEnd(doc3) {
      return findSelectionIn(doc3, doc3, doc3.content.size, doc3.childCount, -1) || new AllSelection(doc3);
    }
    /**
    Deserialize the JSON representation of a selection. Must be
    implemented for custom classes (as a static class method).
    */
    static fromJSON(doc3, json) {
      if (!json || !json.type)
        throw new RangeError("Invalid input for Selection.fromJSON");
      let cls = classesById[json.type];
      if (!cls)
        throw new RangeError(`No selection type ${json.type} defined`);
      return cls.fromJSON(doc3, json);
    }
    /**
    To be able to deserialize selections from JSON, custom selection
    classes must register themselves with an ID string, so that they
    can be disambiguated. Try to pick something that's unlikely to
    clash with classes from other modules.
    */
    static jsonID(id, selectionClass) {
      if (id in classesById)
        throw new RangeError("Duplicate use of selection JSON ID " + id);
      classesById[id] = selectionClass;
      selectionClass.prototype.jsonID = id;
      return selectionClass;
    }
    /**
    Get a [bookmark](https://prosemirror.net/docs/ref/#state.SelectionBookmark) for this selection,
    which is a value that can be mapped without having access to a
    current document, and later resolved to a real selection for a
    given document again. (This is used mostly by the history to
    track and restore old selections.) The default implementation of
    this method just converts the selection to a text selection and
    returns the bookmark for that.
    */
    getBookmark() {
      return TextSelection.between(this.$anchor, this.$head).getBookmark();
    }
  };
  Selection.prototype.visible = true;
  var SelectionRange = class {
    /**
    Create a range.
    */
    constructor($from, $to) {
      this.$from = $from;
      this.$to = $to;
    }
  };
  var warnedAboutTextSelection = false;
  function checkTextSelection($pos) {
    if (!warnedAboutTextSelection && !$pos.parent.inlineContent) {
      warnedAboutTextSelection = true;
      console["warn"]("TextSelection endpoint not pointing into a node with inline content (" + $pos.parent.type.name + ")");
    }
  }
  var TextSelection = class _TextSelection extends Selection {
    /**
    Construct a text selection between the given points.
    */
    constructor($anchor, $head = $anchor) {
      checkTextSelection($anchor);
      checkTextSelection($head);
      super($anchor, $head);
    }
    /**
    Returns a resolved position if this is a cursor selection (an
    empty text selection), and null otherwise.
    */
    get $cursor() {
      return this.$anchor.pos == this.$head.pos ? this.$head : null;
    }
    map(doc3, mapping) {
      let $head = doc3.resolve(mapping.map(this.head));
      if (!$head.parent.inlineContent)
        return Selection.near($head);
      let $anchor = doc3.resolve(mapping.map(this.anchor));
      return new _TextSelection($anchor.parent.inlineContent ? $anchor : $head, $head);
    }
    replace(tr, content = Slice.empty) {
      super.replace(tr, content);
      if (content == Slice.empty) {
        let marks2 = this.$from.marksAcross(this.$to);
        if (marks2)
          tr.ensureMarks(marks2);
      }
    }
    eq(other) {
      return other instanceof _TextSelection && other.anchor == this.anchor && other.head == this.head;
    }
    getBookmark() {
      return new TextBookmark(this.anchor, this.head);
    }
    toJSON() {
      return { type: "text", anchor: this.anchor, head: this.head };
    }
    /**
    @internal
    */
    static fromJSON(doc3, json) {
      if (typeof json.anchor != "number" || typeof json.head != "number")
        throw new RangeError("Invalid input for TextSelection.fromJSON");
      return new _TextSelection(doc3.resolve(json.anchor), doc3.resolve(json.head));
    }
    /**
    Create a text selection from non-resolved positions.
    */
    static create(doc3, anchor, head = anchor) {
      let $anchor = doc3.resolve(anchor);
      return new this($anchor, head == anchor ? $anchor : doc3.resolve(head));
    }
    /**
    Return a text selection that spans the given positions or, if
    they aren't text positions, find a text selection near them.
    `bias` determines whether the method searches forward (default)
    or backwards (negative number) first. Will fall back to calling
    [`Selection.near`](https://prosemirror.net/docs/ref/#state.Selection^near) when the document
    doesn't contain a valid text position.
    */
    static between($anchor, $head, bias) {
      let dPos = $anchor.pos - $head.pos;
      if (!bias || dPos)
        bias = dPos >= 0 ? 1 : -1;
      if (!$head.parent.inlineContent) {
        let found2 = Selection.findFrom($head, bias, true) || Selection.findFrom($head, -bias, true);
        if (found2)
          $head = found2.$head;
        else
          return Selection.near($head, bias);
      }
      if (!$anchor.parent.inlineContent) {
        if (dPos == 0) {
          $anchor = $head;
        } else {
          $anchor = (Selection.findFrom($anchor, -bias, true) || Selection.findFrom($anchor, bias, true)).$anchor;
          if ($anchor.pos < $head.pos != dPos < 0)
            $anchor = $head;
        }
      }
      return new _TextSelection($anchor, $head);
    }
  };
  Selection.jsonID("text", TextSelection);
  var TextBookmark = class _TextBookmark {
    constructor(anchor, head) {
      this.anchor = anchor;
      this.head = head;
    }
    map(mapping) {
      return new _TextBookmark(mapping.map(this.anchor), mapping.map(this.head));
    }
    resolve(doc3) {
      return TextSelection.between(doc3.resolve(this.anchor), doc3.resolve(this.head));
    }
  };
  var NodeSelection = class _NodeSelection extends Selection {
    /**
    Create a node selection. Does not verify the validity of its
    argument.
    */
    constructor($pos) {
      let node = $pos.nodeAfter;
      let $end = $pos.node(0).resolve($pos.pos + node.nodeSize);
      super($pos, $end);
      this.node = node;
    }
    map(doc3, mapping) {
      let { deleted, pos } = mapping.mapResult(this.anchor);
      let $pos = doc3.resolve(pos);
      if (deleted)
        return Selection.near($pos);
      return new _NodeSelection($pos);
    }
    content() {
      return new Slice(Fragment.from(this.node), 0, 0);
    }
    eq(other) {
      return other instanceof _NodeSelection && other.anchor == this.anchor;
    }
    toJSON() {
      return { type: "node", anchor: this.anchor };
    }
    getBookmark() {
      return new NodeBookmark(this.anchor);
    }
    /**
    @internal
    */
    static fromJSON(doc3, json) {
      if (typeof json.anchor != "number")
        throw new RangeError("Invalid input for NodeSelection.fromJSON");
      return new _NodeSelection(doc3.resolve(json.anchor));
    }
    /**
    Create a node selection from non-resolved positions.
    */
    static create(doc3, from2) {
      return new _NodeSelection(doc3.resolve(from2));
    }
    /**
    Determines whether the given node may be selected as a node
    selection.
    */
    static isSelectable(node) {
      return !node.isText && node.type.spec.selectable !== false;
    }
  };
  NodeSelection.prototype.visible = false;
  Selection.jsonID("node", NodeSelection);
  var NodeBookmark = class _NodeBookmark {
    constructor(anchor) {
      this.anchor = anchor;
    }
    map(mapping) {
      let { deleted, pos } = mapping.mapResult(this.anchor);
      return deleted ? new TextBookmark(pos, pos) : new _NodeBookmark(pos);
    }
    resolve(doc3) {
      let $pos = doc3.resolve(this.anchor), node = $pos.nodeAfter;
      if (node && NodeSelection.isSelectable(node))
        return new NodeSelection($pos);
      return Selection.near($pos);
    }
  };
  var AllSelection = class _AllSelection extends Selection {
    /**
    Create an all-selection over the given document.
    */
    constructor(doc3) {
      super(doc3.resolve(0), doc3.resolve(doc3.content.size));
    }
    replace(tr, content = Slice.empty) {
      if (content == Slice.empty) {
        tr.delete(0, tr.doc.content.size);
        let sel = Selection.atStart(tr.doc);
        if (!sel.eq(tr.selection))
          tr.setSelection(sel);
      } else {
        super.replace(tr, content);
      }
    }
    toJSON() {
      return { type: "all" };
    }
    /**
    @internal
    */
    static fromJSON(doc3) {
      return new _AllSelection(doc3);
    }
    map(doc3) {
      return new _AllSelection(doc3);
    }
    eq(other) {
      return other instanceof _AllSelection;
    }
    getBookmark() {
      return AllBookmark;
    }
  };
  Selection.jsonID("all", AllSelection);
  var AllBookmark = {
    map() {
      return this;
    },
    resolve(doc3) {
      return new AllSelection(doc3);
    }
  };
  function findSelectionIn(doc3, node, pos, index, dir, text = false) {
    if (node.inlineContent)
      return TextSelection.create(doc3, pos);
    for (let i = index - (dir > 0 ? 0 : 1); dir > 0 ? i < node.childCount : i >= 0; i += dir) {
      let child = node.child(i);
      if (!child.isAtom) {
        let inner = findSelectionIn(doc3, child, pos + dir, dir < 0 ? child.childCount : 0, dir, text);
        if (inner)
          return inner;
      } else if (!text && NodeSelection.isSelectable(child)) {
        return NodeSelection.create(doc3, pos - (dir < 0 ? child.nodeSize : 0));
      }
      pos += child.nodeSize * dir;
    }
    return null;
  }
  function selectionToInsertionEnd(tr, startLen, bias) {
    let last = tr.steps.length - 1;
    if (last < startLen)
      return;
    let step = tr.steps[last];
    if (!(step instanceof ReplaceStep || step instanceof ReplaceAroundStep))
      return;
    let map2 = tr.mapping.maps[last], end;
    map2.forEach((_from, _to, _newFrom, newTo) => {
      if (end == null)
        end = newTo;
    });
    tr.setSelection(Selection.near(tr.doc.resolve(end), bias));
  }
  var UPDATED_SEL = 1;
  var UPDATED_MARKS = 2;
  var UPDATED_SCROLL = 4;
  var Transaction = class extends Transform {
    /**
    @internal
    */
    constructor(state) {
      super(state.doc);
      this.curSelectionFor = 0;
      this.updated = 0;
      this.meta = /* @__PURE__ */ Object.create(null);
      this.time = Date.now();
      this.curSelection = state.selection;
      this.storedMarks = state.storedMarks;
    }
    /**
    The transaction's current selection. This defaults to the editor
    selection [mapped](https://prosemirror.net/docs/ref/#state.Selection.map) through the steps in the
    transaction, but can be overwritten with
    [`setSelection`](https://prosemirror.net/docs/ref/#state.Transaction.setSelection).
    */
    get selection() {
      if (this.curSelectionFor < this.steps.length) {
        this.curSelection = this.curSelection.map(this.doc, this.mapping.slice(this.curSelectionFor));
        this.curSelectionFor = this.steps.length;
      }
      return this.curSelection;
    }
    /**
    Update the transaction's current selection. Will determine the
    selection that the editor gets when the transaction is applied.
    */
    setSelection(selection) {
      if (selection.$from.doc != this.doc)
        throw new RangeError("Selection passed to setSelection must point at the current document");
      this.curSelection = selection;
      this.curSelectionFor = this.steps.length;
      this.updated = (this.updated | UPDATED_SEL) & ~UPDATED_MARKS;
      this.storedMarks = null;
      return this;
    }
    /**
    Whether the selection was explicitly updated by this transaction.
    */
    get selectionSet() {
      return (this.updated & UPDATED_SEL) > 0;
    }
    /**
    Set the current stored marks.
    */
    setStoredMarks(marks2) {
      this.storedMarks = marks2;
      this.updated |= UPDATED_MARKS;
      return this;
    }
    /**
    Make sure the current stored marks or, if that is null, the marks
    at the selection, match the given set of marks. Does nothing if
    this is already the case.
    */
    ensureMarks(marks2) {
      if (!Mark.sameSet(this.storedMarks || this.selection.$from.marks(), marks2))
        this.setStoredMarks(marks2);
      return this;
    }
    /**
    Add a mark to the set of stored marks.
    */
    addStoredMark(mark) {
      return this.ensureMarks(mark.addToSet(this.storedMarks || this.selection.$head.marks()));
    }
    /**
    Remove a mark or mark type from the set of stored marks.
    */
    removeStoredMark(mark) {
      return this.ensureMarks(mark.removeFromSet(this.storedMarks || this.selection.$head.marks()));
    }
    /**
    Whether the stored marks were explicitly set for this transaction.
    */
    get storedMarksSet() {
      return (this.updated & UPDATED_MARKS) > 0;
    }
    /**
    @internal
    */
    addStep(step, doc3) {
      super.addStep(step, doc3);
      this.updated = this.updated & ~UPDATED_MARKS;
      this.storedMarks = null;
    }
    /**
    Update the timestamp for the transaction.
    */
    setTime(time) {
      this.time = time;
      return this;
    }
    /**
    Replace the current selection with the given slice.
    */
    replaceSelection(slice2) {
      this.selection.replace(this, slice2);
      return this;
    }
    /**
    Replace the selection with the given node. When `inheritMarks` is
    true and the content is inline, it inherits the marks from the
    place where it is inserted.
    */
    replaceSelectionWith(node, inheritMarks = true) {
      let selection = this.selection;
      if (inheritMarks)
        node = node.mark(this.storedMarks || (selection.empty ? selection.$from.marks() : selection.$from.marksAcross(selection.$to) || Mark.none));
      selection.replaceWith(this, node);
      return this;
    }
    /**
    Delete the selection.
    */
    deleteSelection() {
      this.selection.replace(this);
      return this;
    }
    /**
    Replace the given range, or the selection if no range is given,
    with a text node containing the given string.
    */
    insertText(text, from2, to) {
      let schema2 = this.doc.type.schema;
      if (from2 == null) {
        if (!text)
          return this.deleteSelection();
        return this.replaceSelectionWith(schema2.text(text), true);
      } else {
        if (to == null)
          to = from2;
        if (!text)
          return this.deleteRange(from2, to);
        let marks2 = this.storedMarks;
        if (!marks2) {
          let $from = this.doc.resolve(from2);
          marks2 = to == from2 ? $from.marks() : $from.marksAcross(this.doc.resolve(to));
        }
        this.replaceRangeWith(from2, to, schema2.text(text, marks2));
        if (!this.selection.empty && this.selection.to == from2 + text.length)
          this.setSelection(Selection.near(this.selection.$to));
        return this;
      }
    }
    /**
    Store a metadata property in this transaction, keyed either by
    name or by plugin.
    */
    setMeta(key, value) {
      this.meta[typeof key == "string" ? key : key.key] = value;
      return this;
    }
    /**
    Retrieve a metadata property for a given name or plugin.
    */
    getMeta(key) {
      return this.meta[typeof key == "string" ? key : key.key];
    }
    /**
    Returns true if this transaction doesn't contain any metadata,
    and can thus safely be extended.
    */
    get isGeneric() {
      for (let _ in this.meta)
        return false;
      return true;
    }
    /**
    Indicate that the editor should scroll the selection into view
    when updated to the state produced by this transaction.
    */
    scrollIntoView() {
      this.updated |= UPDATED_SCROLL;
      return this;
    }
    /**
    True when this transaction has had `scrollIntoView` called on it.
    */
    get scrolledIntoView() {
      return (this.updated & UPDATED_SCROLL) > 0;
    }
  };
  function bind(f, self) {
    return !self || !f ? f : f.bind(self);
  }
  var FieldDesc = class {
    constructor(name, desc, self) {
      this.name = name;
      this.init = bind(desc.init, self);
      this.apply = bind(desc.apply, self);
    }
  };
  var baseFields = [
    new FieldDesc("doc", {
      init(config) {
        return config.doc || config.schema.topNodeType.createAndFill();
      },
      apply(tr) {
        return tr.doc;
      }
    }),
    new FieldDesc("selection", {
      init(config, instance) {
        return config.selection || Selection.atStart(instance.doc);
      },
      apply(tr) {
        return tr.selection;
      }
    }),
    new FieldDesc("storedMarks", {
      init(config) {
        return config.storedMarks || null;
      },
      apply(tr, _marks, _old, state) {
        return state.selection.$cursor ? tr.storedMarks : null;
      }
    }),
    new FieldDesc("scrollToSelection", {
      init() {
        return 0;
      },
      apply(tr, prev) {
        return tr.scrolledIntoView ? prev + 1 : prev;
      }
    })
  ];
  var Configuration = class {
    constructor(schema2, plugins) {
      this.schema = schema2;
      this.plugins = [];
      this.pluginsByKey = /* @__PURE__ */ Object.create(null);
      this.fields = baseFields.slice();
      if (plugins)
        plugins.forEach((plugin) => {
          if (this.pluginsByKey[plugin.key])
            throw new RangeError("Adding different instances of a keyed plugin (" + plugin.key + ")");
          this.plugins.push(plugin);
          this.pluginsByKey[plugin.key] = plugin;
          if (plugin.spec.state)
            this.fields.push(new FieldDesc(plugin.key, plugin.spec.state, plugin));
        });
    }
  };
  var EditorState = class _EditorState {
    /**
    @internal
    */
    constructor(config) {
      this.config = config;
    }
    /**
    The schema of the state's document.
    */
    get schema() {
      return this.config.schema;
    }
    /**
    The plugins that are active in this state.
    */
    get plugins() {
      return this.config.plugins;
    }
    /**
    Apply the given transaction to produce a new state.
    */
    apply(tr) {
      return this.applyTransaction(tr).state;
    }
    /**
    @internal
    */
    filterTransaction(tr, ignore = -1) {
      for (let i = 0; i < this.config.plugins.length; i++)
        if (i != ignore) {
          let plugin = this.config.plugins[i];
          if (plugin.spec.filterTransaction && !plugin.spec.filterTransaction.call(plugin, tr, this))
            return false;
        }
      return true;
    }
    /**
    Verbose variant of [`apply`](https://prosemirror.net/docs/ref/#state.EditorState.apply) that
    returns the precise transactions that were applied (which might
    be influenced by the [transaction
    hooks](https://prosemirror.net/docs/ref/#state.PluginSpec.filterTransaction) of
    plugins) along with the new state.
    */
    applyTransaction(rootTr) {
      if (!this.filterTransaction(rootTr))
        return { state: this, transactions: [] };
      let trs = [rootTr], newState = this.applyInner(rootTr), seen = null;
      for (; ; ) {
        let haveNew = false;
        for (let i = 0; i < this.config.plugins.length; i++) {
          let plugin = this.config.plugins[i];
          if (plugin.spec.appendTransaction) {
            let n = seen ? seen[i].n : 0, oldState = seen ? seen[i].state : this;
            let tr = n < trs.length && plugin.spec.appendTransaction.call(plugin, n ? trs.slice(n) : trs, oldState, newState);
            if (tr && newState.filterTransaction(tr, i)) {
              tr.setMeta("appendedTransaction", rootTr);
              if (!seen) {
                seen = [];
                for (let j = 0; j < this.config.plugins.length; j++)
                  seen.push(j < i ? { state: newState, n: trs.length } : { state: this, n: 0 });
              }
              trs.push(tr);
              newState = newState.applyInner(tr);
              haveNew = true;
            }
            if (seen)
              seen[i] = { state: newState, n: trs.length };
          }
        }
        if (!haveNew)
          return { state: newState, transactions: trs };
      }
    }
    /**
    @internal
    */
    applyInner(tr) {
      if (!tr.before.eq(this.doc))
        throw new RangeError("Applying a mismatched transaction");
      let newInstance = new _EditorState(this.config), fields = this.config.fields;
      for (let i = 0; i < fields.length; i++) {
        let field = fields[i];
        newInstance[field.name] = field.apply(tr, this[field.name], this, newInstance);
      }
      return newInstance;
    }
    /**
    Accessor that constructs and returns a new [transaction](https://prosemirror.net/docs/ref/#state.Transaction) from this state.
    */
    get tr() {
      return new Transaction(this);
    }
    /**
    Create a new state.
    */
    static create(config) {
      let $config = new Configuration(config.doc ? config.doc.type.schema : config.schema, config.plugins);
      let instance = new _EditorState($config);
      for (let i = 0; i < $config.fields.length; i++)
        instance[$config.fields[i].name] = $config.fields[i].init(config, instance);
      return instance;
    }
    /**
    Create a new state based on this one, but with an adjusted set
    of active plugins. State fields that exist in both sets of
    plugins are kept unchanged. Those that no longer exist are
    dropped, and those that are new are initialized using their
    [`init`](https://prosemirror.net/docs/ref/#state.StateField.init) method, passing in the new
    configuration object..
    */
    reconfigure(config) {
      let $config = new Configuration(this.schema, config.plugins);
      let fields = $config.fields, instance = new _EditorState($config);
      for (let i = 0; i < fields.length; i++) {
        let name = fields[i].name;
        instance[name] = this.hasOwnProperty(name) ? this[name] : fields[i].init(config, instance);
      }
      return instance;
    }
    /**
    Serialize this state to JSON. If you want to serialize the state
    of plugins, pass an object mapping property names to use in the
    resulting JSON object to plugin objects. The argument may also be
    a string or number, in which case it is ignored, to support the
    way `JSON.stringify` calls `toString` methods.
    */
    toJSON(pluginFields) {
      let result = { doc: this.doc.toJSON(), selection: this.selection.toJSON() };
      if (this.storedMarks)
        result.storedMarks = this.storedMarks.map((m) => m.toJSON());
      if (pluginFields && typeof pluginFields == "object")
        for (let prop in pluginFields) {
          if (prop == "doc" || prop == "selection")
            throw new RangeError("The JSON fields `doc` and `selection` are reserved");
          let plugin = pluginFields[prop], state = plugin.spec.state;
          if (state && state.toJSON)
            result[prop] = state.toJSON.call(plugin, this[plugin.key]);
        }
      return result;
    }
    /**
    Deserialize a JSON representation of a state. `config` should
    have at least a `schema` field, and should contain array of
    plugins to initialize the state with. `pluginFields` can be used
    to deserialize the state of plugins, by associating plugin
    instances with the property names they use in the JSON object.
    */
    static fromJSON(config, json, pluginFields) {
      if (!json)
        throw new RangeError("Invalid input for EditorState.fromJSON");
      if (!config.schema)
        throw new RangeError("Required config field 'schema' missing");
      let $config = new Configuration(config.schema, config.plugins);
      let instance = new _EditorState($config);
      $config.fields.forEach((field) => {
        if (field.name == "doc") {
          instance.doc = Node.fromJSON(config.schema, json.doc);
        } else if (field.name == "selection") {
          instance.selection = Selection.fromJSON(instance.doc, json.selection);
        } else if (field.name == "storedMarks") {
          if (json.storedMarks)
            instance.storedMarks = json.storedMarks.map(config.schema.markFromJSON);
        } else {
          if (pluginFields)
            for (let prop in pluginFields) {
              let plugin = pluginFields[prop], state = plugin.spec.state;
              if (plugin.key == field.name && state && state.fromJSON && Object.prototype.hasOwnProperty.call(json, prop)) {
                instance[field.name] = state.fromJSON.call(plugin, config, json[prop], instance);
                return;
              }
            }
          instance[field.name] = field.init(config, instance);
        }
      });
      return instance;
    }
  };
  function bindProps(obj, self, target) {
    for (let prop in obj) {
      let val = obj[prop];
      if (val instanceof Function)
        val = val.bind(self);
      else if (prop == "handleDOMEvents")
        val = bindProps(val, self, {});
      target[prop] = val;
    }
    return target;
  }
  var Plugin = class {
    /**
    Create a plugin.
    */
    constructor(spec) {
      this.spec = spec;
      this.props = {};
      if (spec.props)
        bindProps(spec.props, this, this.props);
      this.key = spec.key ? spec.key.key : createKey("plugin");
    }
    /**
    Extract the plugin's state field from an editor state.
    */
    getState(state) {
      return state[this.key];
    }
  };
  var keys = /* @__PURE__ */ Object.create(null);
  function createKey(name) {
    if (name in keys)
      return name + "$" + ++keys[name];
    keys[name] = 0;
    return name + "$";
  }
  var PluginKey = class {
    /**
    Create a plugin key.
    */
    constructor(name = "key") {
      this.key = createKey(name);
    }
    /**
    Get the active plugin with this key, if any, from an editor
    state.
    */
    get(state) {
      return state.config.pluginsByKey[this.key];
    }
    /**
    Get the plugin's state from an editor state.
    */
    getState(state) {
      return state[this.key];
    }
  };

  // node_modules/prosemirror-view/dist/index.js
  var domIndex = function(node) {
    for (var index = 0; ; index++) {
      node = node.previousSibling;
      if (!node)
        return index;
    }
  };
  function parentNode(node) {
    let parent = node.assignedSlot || node.parentNode;
    return parent && parent.nodeType == 11 ? parent.host : parent;
  }
  var reusedRange = null;
  function textRange(node, from2, to) {
    let range = reusedRange || (reusedRange = document.createRange());
    range.setEnd(node, to == null ? node.nodeValue.length : to);
    range.setStart(node, from2 || 0);
    return range;
  }
  function clearReusedRange() {
    reusedRange = null;
  }
  function isEquivalentPosition(node, off, targetNode, targetOff) {
    return targetNode && (scanFor(node, off, targetNode, targetOff, -1) || scanFor(node, off, targetNode, targetOff, 1));
  }
  var atomElements = /^(img|br|input|textarea|hr)$/i;
  function scanFor(node, off, targetNode, targetOff, dir) {
    var _a;
    for (; ; ) {
      if (node == targetNode && off == targetOff)
        return true;
      if (off == (dir < 0 ? 0 : nodeSize(node))) {
        let parent = node.parentNode;
        if (!parent || !isElt(parent) || hasNodeDesc(node) || atomElements.test(node.nodeName) || node.contentEditable == "false")
          return false;
        off = domIndex(node) + (dir < 0 ? 0 : 1);
        node = parent;
      } else if (isElt(node)) {
        let child = node.childNodes[off + (dir < 0 ? -1 : 0)];
        if (isElt(child) && child.contentEditable == "false") {
          if ((_a = child.pmViewDesc) === null || _a === void 0 ? void 0 : _a.ignoreForSelection)
            off += dir;
          else
            return false;
        } else if (hasNodeDesc(child) || atomElements.test(child.nodeName)) {
          return false;
        } else {
          node = child;
          off = dir < 0 ? nodeSize(node) : 0;
        }
      } else {
        return false;
      }
    }
  }
  function nodeSize(node) {
    return node.nodeType == 3 ? node.nodeValue.length : node.childNodes.length;
  }
  function isElt(node) {
    return node.nodeType == 1;
  }
  function isText(node) {
    return node.nodeType == 3;
  }
  function contains(parent, child) {
    return child ? parent.contains(isElt(child) ? child : child.parentNode) : false;
  }
  function textNodeBefore(node, offset) {
    for (; ; ) {
      if (isText(node) && offset)
        return node;
      if (isElt(node) && offset > 0) {
        if (node.contentEditable == "false")
          return null;
        node = node.childNodes[offset - 1];
        offset = nodeSize(node);
      } else if (node.parentNode && !hasNodeDesc(node, true)) {
        offset = domIndex(node);
        node = node.parentNode;
      } else {
        return null;
      }
    }
  }
  function textNodeAfter(node, offset) {
    for (; ; ) {
      if (isText(node) && offset < node.nodeValue.length)
        return node;
      if (isElt(node) && offset < node.childNodes.length) {
        if (node.contentEditable == "false")
          return null;
        node = node.childNodes[offset];
        offset = 0;
      } else if (node.parentNode && !hasNodeDesc(node, true)) {
        offset = domIndex(node) + 1;
        node = node.parentNode;
      } else {
        return null;
      }
    }
  }
  function isOnEdge(node, offset, parent) {
    for (let atStart = offset == 0, atEnd = offset == nodeSize(node); atStart || atEnd; ) {
      if (node == parent)
        return true;
      let index = domIndex(node);
      node = node.parentNode;
      if (!node)
        return false;
      atStart = atStart && index == 0;
      atEnd = atEnd && index == nodeSize(node);
    }
  }
  function hasNodeDesc(dom, isBlock = false) {
    let desc;
    for (let cur = dom; cur; cur = cur.parentNode)
      if (desc = cur.pmViewDesc)
        break;
    return desc && desc.node && (!isBlock || desc.node.isBlock) && (desc.dom == dom || desc.contentDOM == dom);
  }
  function selectionCollapsed(domSel) {
    return domSel.focusNode && isEquivalentPosition(domSel.focusNode, domSel.focusOffset, domSel.anchorNode, domSel.anchorOffset);
  }
  function writeSelection(sel, range) {
    sel.collapse(range.anchorNode, range.anchorOffset);
    if (range.focusNode != range.anchorNode || range.focusOffset != range.anchorOffset)
      sel.extend(range.focusNode, range.focusOffset);
  }
  function keyEvent(keyCode, key) {
    let event = document.createEvent("Event");
    event.initEvent("keydown", true, true);
    event.keyCode = keyCode;
    event.key = event.code = key;
    return event;
  }
  function deepActiveElement(doc3) {
    let elt = doc3.activeElement;
    while (elt && elt.shadowRoot)
      elt = elt.shadowRoot.activeElement;
    return elt;
  }
  function caretFromPoint(doc3, x, y) {
    if (doc3.caretPositionFromPoint) {
      try {
        let pos = doc3.caretPositionFromPoint(x, y);
        if (pos)
          return { node: pos.offsetNode, offset: Math.min(nodeSize(pos.offsetNode), pos.offset) };
      } catch (_) {
      }
    }
    if (doc3.caretRangeFromPoint) {
      let range = doc3.caretRangeFromPoint(x, y);
      if (range)
        return { node: range.startContainer, offset: Math.min(nodeSize(range.startContainer), range.startOffset) };
    }
  }
  var nav = typeof navigator != "undefined" ? navigator : null;
  var doc2 = typeof document != "undefined" ? document : null;
  var agent = nav && nav.userAgent || "";
  var gecko = /gecko\/(\d+)/i.test(agent) && !/edge?\//i.test(agent);
  gecko && +(/Firefox\/(\d+)/.exec(agent) || [0, 0])[1];
  var _chrome = /Chrome\/(\d+)/.exec(agent);
  var chrome = !!_chrome;
  var chrome_version = _chrome ? +_chrome[1] : 0;
  var safari = !!nav && /Apple Computer/.test(nav.vendor);
  var ios = safari && (/Mobile\/\w+/.test(agent) || !!nav && nav.maxTouchPoints > 2);
  var mac = ios || (nav ? /Mac/.test(nav.platform) : false);
  var windows = nav ? /Win/.test(nav.platform) : false;
  var android = /Android \d/.test(agent);
  var webkit = !!doc2 && "webkitFontSmoothing" in doc2.documentElement.style;
  var webkit_version = webkit ? +(/\bAppleWebKit\/(\d+)/.exec(navigator.userAgent) || [0, 0])[1] : 0;
  function windowRect(doc3) {
    let vp = doc3.defaultView && doc3.defaultView.visualViewport;
    if (vp)
      return {
        left: 0,
        right: vp.width,
        top: 0,
        bottom: vp.height
      };
    return {
      left: 0,
      right: doc3.documentElement.clientWidth,
      top: 0,
      bottom: doc3.documentElement.clientHeight
    };
  }
  function getSide(value, side) {
    return typeof value == "number" ? value : value[side];
  }
  function clientRect(node) {
    let rect = node.getBoundingClientRect();
    let scaleX = rect.width / node.offsetWidth || 1;
    let scaleY = rect.height / node.offsetHeight || 1;
    return {
      left: rect.left,
      right: rect.left + node.clientWidth * scaleX,
      top: rect.top,
      bottom: rect.top + node.clientHeight * scaleY
    };
  }
  function rectNextTo(node, offset, dir) {
    for (; ; ) {
      if (dir < 0 ? offset : offset < nodeSize(node)) {
        if (isText(node))
          return singleRect(textRange(node, offset + (dir < 0 ? -1 : 0), offset + (dir > 0 ? 1 : 0)), -dir);
        let next = node.childNodes[dir < 0 ? offset - 1 : offset];
        if (isText(next)) {
          node = next;
          offset = dir < 0 ? next.nodeValue.length : 0;
        } else if (isElt(next))
          return singleRect(next, -dir);
        else
          return null;
      } else if (hasNodeDesc(node, true) || !node.parentNode) {
        return null;
      } else {
        offset = domIndex(node) + (dir < 0 ? 0 : 1);
        node = node.parentNode;
      }
    }
  }
  function scrollRectIntoView(view, rect, startDOM) {
    if (!nonZero(rect) && rect.left == 0)
      return;
    let scrollThreshold = view.someProp("scrollThreshold") || 0, scrollMargin = view.someProp("scrollMargin") || 5;
    let doc3 = view.dom.ownerDocument;
    for (let parent = startDOM || view.dom; ; ) {
      if (!parent)
        break;
      if (!isElt(parent)) {
        parent = parentNode(parent);
        continue;
      }
      let atTop = parent == doc3.body;
      let bounding = atTop ? windowRect(doc3) : clientRect(parent);
      let moveX = 0, moveY = 0;
      if (rect.top < bounding.top + getSide(scrollThreshold, "top"))
        moveY = -(bounding.top - rect.top + getSide(scrollMargin, "top"));
      else if (rect.bottom > bounding.bottom - getSide(scrollThreshold, "bottom"))
        moveY = rect.bottom - rect.top > bounding.bottom - bounding.top ? rect.top + getSide(scrollMargin, "top") - bounding.top : rect.bottom - bounding.bottom + getSide(scrollMargin, "bottom");
      if (rect.left < bounding.left + getSide(scrollThreshold, "left"))
        moveX = -(bounding.left - rect.left + getSide(scrollMargin, "left"));
      else if (rect.right > bounding.right - getSide(scrollThreshold, "right"))
        moveX = rect.right - bounding.right + getSide(scrollMargin, "right");
      if (moveX || moveY) {
        if (atTop) {
          doc3.defaultView.scrollBy(moveX, moveY);
        } else {
          let startX = parent.scrollLeft, startY = parent.scrollTop;
          if (moveY)
            parent.scrollTop += moveY;
          if (moveX)
            parent.scrollLeft += moveX;
          let dX = parent.scrollLeft - startX, dY = parent.scrollTop - startY;
          rect = { left: rect.left - dX, top: rect.top - dY, right: rect.right - dX, bottom: rect.bottom - dY };
        }
      }
      let pos = atTop ? "fixed" : getComputedStyle(parent).position;
      if (/^(fixed|sticky)$/.test(pos))
        break;
      parent = pos == "absolute" ? parent.offsetParent : parentNode(parent);
    }
  }
  function storeScrollPos(view) {
    let rect = view.dom.getBoundingClientRect(), startY = Math.max(0, rect.top);
    let refDOM, refTop;
    for (let x = (rect.left + rect.right) / 2, y = startY + 1; y < Math.min(innerHeight, rect.bottom); y += 5) {
      let dom = view.root.elementFromPoint(x, y);
      if (!dom || dom == view.dom || !view.dom.contains(dom))
        continue;
      let localRect = dom.getBoundingClientRect();
      if (localRect.top >= startY - 20) {
        refDOM = dom;
        refTop = localRect.top;
        break;
      }
    }
    return { refDOM, refTop, stack: scrollStack(view.dom) };
  }
  function scrollStack(dom) {
    let stack = [], doc3 = dom.ownerDocument;
    for (let cur = dom; cur; cur = parentNode(cur)) {
      stack.push({ dom: cur, top: cur.scrollTop, left: cur.scrollLeft });
      if (dom == doc3)
        break;
    }
    return stack;
  }
  function resetScrollPos({ refDOM, refTop, stack }) {
    let newRefTop = refDOM ? refDOM.getBoundingClientRect().top : 0;
    restoreScrollStack(stack, newRefTop == 0 ? 0 : newRefTop - refTop);
  }
  function restoreScrollStack(stack, dTop) {
    for (let i = 0; i < stack.length; i++) {
      let { dom, top, left } = stack[i];
      if (dom.scrollTop != top + dTop)
        dom.scrollTop = top + dTop;
      if (dom.scrollLeft != left)
        dom.scrollLeft = left;
    }
  }
  var preventScrollSupported = null;
  function focusPreventScroll(dom) {
    if (dom.setActive)
      return dom.setActive();
    if (preventScrollSupported)
      return dom.focus(preventScrollSupported);
    let stored = scrollStack(dom);
    dom.focus(preventScrollSupported == null ? {
      get preventScroll() {
        preventScrollSupported = { preventScroll: true };
        return true;
      }
    } : void 0);
    if (!preventScrollSupported) {
      preventScrollSupported = false;
      restoreScrollStack(stored, 0);
    }
  }
  function findOffsetInNode(node, coords) {
    let closest;
    let dxClosest = 2e8, coordsClosest, offset = 0;
    let rowBot = coords.top, rowTop = coords.top;
    let firstBelow, coordsBelow;
    for (let child = node.firstChild, childIndex = 0; child; child = child.nextSibling, childIndex++) {
      let rects;
      if (isElt(child))
        rects = child.getClientRects();
      else if (isText(child))
        rects = textRange(child).getClientRects();
      else
        continue;
      for (let i = 0; i < rects.length; i++) {
        let rect = rects[i];
        if (rect.top <= rowBot && rect.bottom >= rowTop) {
          rowBot = Math.max(rect.bottom, rowBot);
          rowTop = Math.min(rect.top, rowTop);
          let dx = rect.left > coords.left ? rect.left - coords.left : rect.right < coords.left ? coords.left - rect.right : 0;
          if (dx < dxClosest) {
            closest = child;
            dxClosest = dx;
            coordsClosest = dx && isText(closest) ? {
              left: rect.right < coords.left ? rect.right : rect.left,
              top: coords.top
            } : coords;
            if (isElt(child) && dx)
              offset = childIndex + (coords.left >= (rect.left + rect.right) / 2 ? 1 : 0);
            continue;
          }
        } else if (rect.top > coords.top && !firstBelow && rect.left <= coords.left && rect.right >= coords.left) {
          firstBelow = child;
          coordsBelow = { left: Math.max(rect.left, Math.min(rect.right, coords.left)), top: rect.top };
        }
        if (!closest && (coords.left >= rect.right && coords.top >= rect.top || coords.left >= rect.left && coords.top >= rect.bottom))
          offset = childIndex + 1;
      }
    }
    if (!closest && firstBelow) {
      closest = firstBelow;
      coordsClosest = coordsBelow;
      dxClosest = 0;
    }
    if (closest && isText(closest))
      return findOffsetInText(closest, coordsClosest);
    if (!closest || dxClosest)
      return { node, offset };
    return findOffsetInNode(closest, coordsClosest);
  }
  function findOffsetInText(node, coords) {
    let len = node.nodeValue.length;
    let range = document.createRange(), result;
    for (let i = 0; i < len; i++) {
      range.setEnd(node, i + 1);
      range.setStart(node, i);
      let rect = singleRect(range, 1);
      if (rect.top == rect.bottom)
        continue;
      if (inRect(coords, rect)) {
        result = { node, offset: i + (coords.left >= (rect.left + rect.right) / 2 ? 1 : 0) };
        break;
      }
    }
    range.detach();
    return result || { node, offset: 0 };
  }
  function inRect(coords, rect) {
    return coords.left >= rect.left - 1 && coords.left <= rect.right + 1 && coords.top >= rect.top - 1 && coords.top <= rect.bottom + 1;
  }
  function targetKludge(dom, coords) {
    let parent = dom.parentNode;
    if (parent && /^li$/i.test(parent.nodeName) && coords.left < dom.getBoundingClientRect().left)
      return parent;
    return dom;
  }
  function posFromElement(view, elt, coords) {
    let { node, offset } = findOffsetInNode(elt, coords), bias = -1;
    if (isElt(node) && !node.firstChild) {
      let rect = node.getBoundingClientRect();
      bias = rect.left != rect.right && coords.left > (rect.left + rect.right) / 2 ? 1 : -1;
    }
    return { pos: view.docView.posFromDOM(node, offset, bias), affinity: affinityFromCoords(node, offset, coords) };
  }
  function horizDist(x, rect) {
    return x < rect.left ? rect.left - x : x > rect.right ? x - rect.right : 0;
  }
  function affinityFromCoords(node, offset, coords) {
    let before = rectNextTo(node, offset, -1), after = rectNextTo(node, offset, 1);
    if (!before)
      return 1;
    if (!after)
      return -1;
    if (before.bottom <= after.top)
      return coords.top > (before.bottom + after.top) / 2 ? 1 : -1;
    return horizDist(coords.left, before) < horizDist(coords.left, after) ? -1 : 1;
  }
  function posFromCaret(view, node, offset, coords) {
    let outsideBlock = -1;
    for (let cur = node; cur != view.dom; ) {
      let desc = view.docView.nearestDesc(cur, true), rect;
      if (!desc)
        return null;
      if (isElt(desc.dom) && ((rect = desc.dom.getBoundingClientRect()).width || rect.height)) {
        if (!desc.contentDOM && !desc.node.isText && coords.left >= rect.left && coords.left <= rect.right && coords.top >= rect.top && coords.top <= rect.bottom) {
          let before = desc.node.isBlock ? coords.top < (rect.top + rect.bottom) / 2 : coords.left < (rect.left + rect.right) / 2;
          return { pos: before ? desc.posBefore : desc.posAfter, affinity: before ? 1 : -1 };
        }
        if (desc.node.isBlock && desc.parent && !/^T(R|BODY|HEAD|FOOT)$/.test(desc.dom.nodeName) && (coords.top < rect.top || coords.top > rect.bottom)) {
          outsideBlock = coords.top < rect.top ? desc.posBefore : desc.posAfter;
        }
      }
      cur = desc.dom.parentNode;
    }
    if (outsideBlock > -1)
      return { pos: outsideBlock, affinity: 0 };
    return {
      pos: view.docView.posFromDOM(node, offset, -1),
      affinity: affinityFromCoords(node, offset, coords)
    };
  }
  function elementFromPoint(element, coords, box) {
    let len = element.childNodes.length;
    if (len && box.top < box.bottom) {
      for (let startI = Math.max(0, Math.min(len - 1, Math.floor(len * (coords.top - box.top) / (box.bottom - box.top)) - 2)), i = startI; ; ) {
        let child = element.childNodes[i];
        if (isElt(child)) {
          let rects = child.getClientRects();
          for (let j = 0; j < rects.length; j++) {
            let rect = rects[j];
            if (inRect(coords, rect))
              return elementFromPoint(child, coords, rect);
          }
        }
        if ((i = (i + 1) % len) == startI)
          break;
      }
    }
    return element;
  }
  function posAtCoords(view, coords) {
    let doc3 = view.dom.ownerDocument, node, offset = 0;
    let caret = caretFromPoint(doc3, coords.left, coords.top);
    if (caret)
      ({ node, offset } = caret);
    let elt = (view.root.elementFromPoint ? view.root : doc3).elementFromPoint(coords.left, coords.top);
    let pos, affinity = 0;
    if (!elt || !view.dom.contains(elt)) {
      let box = view.dom.getBoundingClientRect();
      if (!inRect(coords, box))
        return null;
      elt = elementFromPoint(view.dom, coords, box);
      if (!elt)
        return null;
    }
    if (safari) {
      for (let p = elt; node && p; p = parentNode(p))
        if (p.draggable)
          node = void 0;
    }
    elt = targetKludge(elt, coords);
    if (node) {
      if (gecko && isElt(node)) {
        offset = Math.min(offset, node.childNodes.length);
        if (offset < node.childNodes.length) {
          let next = node.childNodes[offset], box;
          if (next.nodeName == "IMG" && (box = next.getBoundingClientRect()).right <= coords.left && box.bottom > coords.top)
            offset++;
        }
      }
      let prev;
      if (webkit && offset && isElt(node) && isElt(prev = node.childNodes[offset - 1]) && prev.contentEditable == "false" && prev.getBoundingClientRect().top >= coords.top)
        offset--;
      if (node == view.dom && offset == node.childNodes.length - 1 && isElt(node.lastChild) && coords.top > node.lastChild.getBoundingClientRect().bottom) {
        pos = view.state.doc.content.size;
      } else if (offset == 0 || !isElt(node) || node.childNodes[offset - 1].nodeName != "BR") {
        let found2 = posFromCaret(view, node, offset, coords);
        if (found2)
          ({ pos, affinity } = found2);
      }
    }
    if (pos == null)
      ({ pos, affinity } = posFromElement(view, elt, coords));
    let desc = view.docView.nearestDesc(elt, true);
    return { pos, inside: desc ? desc.posAtStart - desc.border : -1, affinity };
  }
  function nonZero(rect) {
    return rect.top < rect.bottom || rect.left < rect.right;
  }
  function singleRect(target, bias) {
    let rects = target.getClientRects();
    if (rects.length) {
      let first = rects[bias < 0 ? 0 : rects.length - 1];
      if (nonZero(first))
        return first;
    }
    return Array.prototype.find.call(rects, nonZero) || target.getBoundingClientRect();
  }
  var BIDI = /[\u0590-\u05f4\u0600-\u06ff\u0700-\u08ac]/;
  function coordsAtPos(view, pos, side) {
    let { node, offset, atom } = view.docView.domFromPos(pos, side < 0 ? -1 : 1);
    let supportEmptyRange = webkit || gecko;
    if (isText(node)) {
      if (supportEmptyRange && (BIDI.test(node.nodeValue) || (side < 0 ? !offset : offset == node.nodeValue.length))) {
        let rect = singleRect(textRange(node, offset, offset), side);
        if (gecko && offset && /\s/.test(node.nodeValue[offset - 1]) && offset < node.nodeValue.length) {
          let rectBefore = singleRect(textRange(node, offset - 1, offset - 1), -1);
          if (rectBefore.top == rect.top) {
            let rectAfter = singleRect(textRange(node, offset, offset + 1), -1);
            if (rectAfter.top != rect.top)
              return flattenV(rectAfter, rectAfter.left < rectBefore.left);
          }
        }
        return rect;
      } else {
        let from2 = offset, to = offset, takeSide = side < 0 ? 1 : -1;
        if (side < 0 && !offset) {
          to++;
          takeSide = -1;
        } else if (side >= 0 && offset == node.nodeValue.length) {
          from2--;
          takeSide = 1;
        } else if (side < 0) {
          from2--;
        } else {
          to++;
        }
        return flattenV(singleRect(textRange(node, from2, to), takeSide), takeSide < 0);
      }
    }
    let $dom = view.state.doc.resolve(pos - (atom || 0));
    if (!$dom.parent.inlineContent) {
      if (atom == null && offset && (side < 0 || offset == nodeSize(node))) {
        let before = node.childNodes[offset - 1];
        if (isElt(before))
          return flattenH(before.getBoundingClientRect(), false);
      }
      if (atom == null && offset < nodeSize(node)) {
        let after = node.childNodes[offset];
        if (isElt(after))
          return flattenH(after.getBoundingClientRect(), true);
      }
      return flattenH(node.getBoundingClientRect(), side >= 0);
    }
    if (atom == null && offset && (side < 0 || offset == nodeSize(node))) {
      let before = node.childNodes[offset - 1];
      let target = isText(before) ? textRange(before, nodeSize(before) - (supportEmptyRange ? 0 : 1)) : isElt(before) && (before.nodeName != "BR" || !before.nextSibling) ? before : null;
      if (target)
        return flattenV(singleRect(target, 1), false);
    }
    if (atom == null && offset < nodeSize(node)) {
      let after = node.childNodes[offset];
      while (after.pmViewDesc && after.pmViewDesc.ignoreForCoords)
        after = after.nextSibling;
      let target = !after ? null : isText(after) ? textRange(after, 0, supportEmptyRange ? 0 : 1) : isElt(after) ? after : null;
      if (target)
        return flattenV(singleRect(target, -1), true);
    }
    return flattenV(singleRect(isText(node) ? textRange(node) : node, -side), side >= 0);
  }
  function flattenV(rect, left) {
    if (rect.width == 0)
      return rect;
    let x = left ? rect.left : rect.right;
    return { top: rect.top, bottom: rect.bottom, left: x, right: x };
  }
  function flattenH(rect, top) {
    if (rect.height == 0)
      return rect;
    let y = top ? rect.top : rect.bottom;
    return { top: y, bottom: y, left: rect.left, right: rect.right };
  }
  function withFlushedState(view, state, f) {
    let viewState = view.state, active = view.root.activeElement;
    if (viewState != state)
      view.updateState(state);
    if (active != view.dom)
      view.focus();
    try {
      return f();
    } finally {
      if (viewState != state)
        view.updateState(viewState);
      if (active != view.dom && active)
        active.focus();
    }
  }
  function endOfTextblockVertical(view, state, dir) {
    let sel = state.selection;
    let $pos = dir == "up" ? sel.$from : sel.$to;
    return withFlushedState(view, state, () => {
      let { node: dom } = view.docView.domFromPos($pos.pos, dir == "up" ? -1 : 1);
      for (; ; ) {
        let nearest = view.docView.nearestDesc(dom, true);
        if (!nearest)
          break;
        if (nearest.node.isBlock) {
          dom = nearest.contentDOM || nearest.dom;
          break;
        }
        dom = nearest.dom.parentNode;
      }
      let coords = coordsAtPos(view, $pos.pos, 1);
      for (let child = dom.firstChild; child; child = child.nextSibling) {
        let boxes;
        if (isElt(child))
          boxes = child.getClientRects();
        else if (isText(child))
          boxes = textRange(child, 0, child.nodeValue.length).getClientRects();
        else
          continue;
        for (let i = 0; i < boxes.length; i++) {
          let box = boxes[i];
          if (box.bottom > box.top + 1 && (dir == "up" ? coords.top - box.top > (box.bottom - coords.top) * 2 : box.bottom - coords.bottom > (coords.bottom - box.top) * 2))
            return false;
        }
      }
      return true;
    });
  }
  var maybeRTL = /[\u0590-\u08ac]/;
  function endOfTextblockHorizontal(view, state, dir) {
    let { $head } = state.selection;
    if (!$head.parent.isTextblock)
      return false;
    let offset = $head.parentOffset, atStart = !offset, atEnd = offset == $head.parent.content.size;
    let sel = view.domSelection();
    if (!sel)
      return $head.pos == $head.start() || $head.pos == $head.end();
    if (!maybeRTL.test($head.parent.textContent) || !sel.modify)
      return dir == "left" || dir == "backward" ? atStart : atEnd;
    return withFlushedState(view, state, () => {
      let range = view.domSel.readRange();
      let oldBidiLevel = sel.caretBidiLevel;
      sel.modify("move", dir, "character");
      let parentDOM = $head.depth ? view.docView.domAfterPos($head.before()) : view.dom;
      let { focusNode: newNode, focusOffset: newOff } = view.domSel.readRange();
      let result = newNode && !contains(parentDOM, newNode) || range.focusNode == newNode && range.focusOffset == newOff;
      writeSelection(sel, range);
      if (oldBidiLevel != null)
        sel.caretBidiLevel = oldBidiLevel;
      return result;
    });
  }
  var cachedState = null;
  var cachedDir = null;
  var cachedResult = false;
  function endOfTextblock(view, state, dir) {
    if (cachedState == state && cachedDir == dir)
      return cachedResult;
    cachedState = state;
    cachedDir = dir;
    return cachedResult = dir == "up" || dir == "down" ? endOfTextblockVertical(view, state, dir) : endOfTextblockHorizontal(view, state, dir);
  }
  var ViewDesc = class {
    constructor(parent, children, dom, contentDOM) {
      this.parent = parent;
      this.children = children;
      this.dom = dom;
      this.contentDOM = contentDOM;
      this.damage = 0;
      dom.pmViewDesc = this;
    }
    // Used to check whether a given description corresponds to a
    // widget/mark/node.
    matchesWidget(widget) {
      return false;
    }
    matchesMark(mark) {
      return false;
    }
    matchesNode(node, outerDeco, innerDeco) {
      return false;
    }
    matchesHack(nodeName) {
      return false;
    }
    // When parsing in-editor content (in domchange.js), we allow
    // descriptions to determine the parse rules that should be used to
    // parse them.
    parseRule(addedNodes) {
      return null;
    }
    // Used by the editor's event handler to ignore events that come
    // from certain descs.
    stopEvent(event) {
      return false;
    }
    // The size of the content represented by this desc.
    get size() {
      let size = 0;
      for (let i = 0; i < this.children.length; i++)
        size += this.children[i].size;
      return size;
    }
    // For block nodes, this represents the space taken up by their
    // start/end tokens.
    get border() {
      return 0;
    }
    destroy() {
      this.parent = void 0;
      if (this.dom.pmViewDesc == this)
        this.dom.pmViewDesc = void 0;
      for (let i = 0; i < this.children.length; i++)
        this.children[i].destroy();
    }
    posBeforeChild(child) {
      for (let i = 0, pos = this.posAtStart; ; i++) {
        let cur = this.children[i];
        if (cur == child)
          return pos;
        pos += cur.size;
      }
    }
    get posBefore() {
      return this.parent.posBeforeChild(this);
    }
    get posAtStart() {
      return this.parent ? this.parent.posBeforeChild(this) + this.border : 0;
    }
    get posAfter() {
      return this.posBefore + this.size;
    }
    get posAtEnd() {
      return this.posAtStart + this.size - 2 * this.border;
    }
    localPosFromDOM(dom, offset, bias) {
      if (this.contentDOM && contains(this.contentDOM, dom)) {
        if (bias < 0) {
          let domBefore, desc;
          if (dom == this.contentDOM) {
            domBefore = dom.childNodes[offset - 1];
          } else {
            while (dom.parentNode != this.contentDOM)
              dom = dom.parentNode;
            domBefore = dom.previousSibling;
          }
          while (domBefore && !((desc = domBefore.pmViewDesc) && desc.parent == this))
            domBefore = domBefore.previousSibling;
          return domBefore ? this.posBeforeChild(desc) + desc.size : this.posAtStart;
        } else {
          let domAfter, desc;
          if (dom == this.contentDOM) {
            domAfter = dom.childNodes[offset];
          } else {
            while (dom.parentNode != this.contentDOM)
              dom = dom.parentNode;
            domAfter = dom.nextSibling;
          }
          while (domAfter && !((desc = domAfter.pmViewDesc) && desc.parent == this))
            domAfter = domAfter.nextSibling;
          return domAfter ? this.posBeforeChild(desc) : this.posAtEnd;
        }
      }
      let atEnd;
      if (dom == this.dom && this.contentDOM) {
        atEnd = offset > domIndex(this.contentDOM);
      } else if (this.contentDOM && this.contentDOM != this.dom && this.dom.contains(this.contentDOM)) {
        let rel = dom.compareDocumentPosition(this.contentDOM);
        if (rel & 16) {
          atEnd = offset > Array.from(dom.childNodes).findIndex((n) => n.contains(this.contentDOM));
        } else {
          atEnd = !(rel & 4);
        }
      } else if (this.dom.firstChild) {
        if (offset == 0)
          for (let search = dom; ; search = search.parentNode) {
            if (search == this.dom) {
              atEnd = false;
              break;
            }
            if (search.previousSibling)
              break;
          }
        if (atEnd == null && offset == dom.childNodes.length)
          for (let search = dom; ; search = search.parentNode) {
            if (search == this.dom) {
              atEnd = true;
              break;
            }
            if (search.nextSibling)
              break;
          }
      }
      return (atEnd == null ? bias > 0 : atEnd) ? this.posAtEnd : this.posAtStart;
    }
    nearestDesc(dom, onlyNodes = false) {
      for (let first = true, cur = dom; cur; cur = cur.parentNode) {
        let desc = this.getDesc(cur), nodeDOM;
        if (desc && (!onlyNodes || desc.node)) {
          if (first && (nodeDOM = desc.nodeDOM) && !(isElt(nodeDOM) ? contains(nodeDOM, dom) : nodeDOM == dom))
            first = false;
          else
            return desc;
        }
      }
    }
    getDesc(dom) {
      let desc = dom.pmViewDesc;
      for (let cur = desc; cur; cur = cur.parent)
        if (cur == this)
          return desc;
    }
    posFromDOM(dom, offset, bias) {
      for (let scan = dom; scan; scan = scan.parentNode) {
        let desc = this.getDesc(scan);
        if (desc)
          return desc.localPosFromDOM(dom, offset, bias);
      }
      return -1;
    }
    // Find the desc for the node after the given pos, if any. (When a
    // parent node overrode rendering, there might not be one.)
    descAt(pos) {
      for (let i = 0, offset = 0; i < this.children.length; i++) {
        let child = this.children[i], end = offset + child.size;
        if (offset == pos && end != offset) {
          while (!child.border && child.children.length) {
            for (let i2 = 0; i2 < child.children.length; i2++) {
              let inner = child.children[i2];
              if (inner.size) {
                child = inner;
                break;
              }
            }
          }
          return child;
        }
        if (pos < end)
          return child.descAt(pos - offset - child.border);
        offset = end;
      }
    }
    domFromPos(pos, side) {
      if (!this.contentDOM)
        return { node: this.dom, offset: 0, atom: pos + 1 };
      let i = 0, offset = 0;
      for (let curPos = 0; i < this.children.length; i++) {
        let child = this.children[i], end = curPos + child.size;
        if (end > pos) {
          offset = pos - curPos;
          break;
        }
        curPos = end;
      }
      if (offset)
        return this.children[i].domFromPos(offset - this.children[i].border, side);
      for (; i > 0; i--) {
        let prev = this.children[i - 1];
        if (prev.size || !(prev instanceof BufferHackViewDesc || prev instanceof WidgetViewDesc && prev.side >= 0))
          break;
      }
      if (side <= 0) {
        let prev, enter = true;
        for (; ; i--, enter = false) {
          prev = i ? this.children[i - 1] : null;
          if (!prev || prev.dom.parentNode == this.contentDOM)
            break;
        }
        if (prev && side && enter && !prev.border && !prev.domAtom)
          return prev.domFromPos(prev.size, side);
        return { node: this.contentDOM, offset: prev ? domIndex(prev.dom) + 1 : 0 };
      } else {
        let next, enter = true;
        for (; ; i++, enter = false) {
          next = i < this.children.length ? this.children[i] : null;
          if (!next || next.dom.parentNode == this.contentDOM)
            break;
        }
        if (next && enter && !next.border && !next.domAtom)
          return next.domFromPos(0, side);
        return { node: this.contentDOM, offset: next ? domIndex(next.dom) : this.contentDOM.childNodes.length };
      }
    }
    // Used to find a DOM range in a single parent for a given changed
    // range.
    parseRange(from2, to, base2 = 0) {
      if (this.children.length == 0)
        return { node: this.contentDOM, from: from2, to, fromOffset: 0, toOffset: this.contentDOM.childNodes.length };
      let fromOffset = -1, toOffset = -1;
      for (let offset = base2, i = 0; ; i++) {
        let child = this.children[i], end = offset + child.size;
        if (fromOffset == -1 && from2 <= end) {
          let childBase = offset + child.border;
          if (from2 >= childBase && to <= end - child.border && child.node && child.contentDOM && this.contentDOM.contains(child.contentDOM))
            return child.parseRange(from2, to, childBase);
          from2 = offset;
          for (let j = i; j > 0; j--) {
            let prev = this.children[j - 1];
            if (prev.size && prev.dom.parentNode == this.contentDOM && !prev.emptyChildAt(1)) {
              fromOffset = domIndex(prev.dom) + 1;
              break;
            }
            from2 -= prev.size;
          }
          if (fromOffset == -1)
            fromOffset = 0;
        }
        if (fromOffset > -1 && (end > to || i == this.children.length - 1)) {
          to = end;
          for (let j = i + 1; j < this.children.length; j++) {
            let next = this.children[j];
            if (next.size && next.dom.parentNode == this.contentDOM && !next.emptyChildAt(-1)) {
              toOffset = domIndex(next.dom);
              break;
            }
            to += next.size;
          }
          if (toOffset == -1)
            toOffset = this.contentDOM.childNodes.length;
          break;
        }
        offset = end;
      }
      return { node: this.contentDOM, from: from2, to, fromOffset, toOffset };
    }
    emptyChildAt(side) {
      if (this.border || !this.contentDOM || !this.children.length)
        return false;
      let child = this.children[side < 0 ? 0 : this.children.length - 1];
      return child.size == 0 || child.emptyChildAt(side);
    }
    domAfterPos(pos) {
      let { node, offset } = this.domFromPos(pos, 0);
      if (!isElt(node) || offset == node.childNodes.length)
        throw new RangeError("No node after pos " + pos);
      return node.childNodes[offset];
    }
    ignoreMutation(mutation) {
      return !this.contentDOM && mutation.type != "selection";
    }
    get contentLost() {
      return this.contentDOM && this.contentDOM != this.dom && !this.dom.contains(this.contentDOM);
    }
    markDamage(damage) {
      if (damage) {
        this.damage |= damage;
        this.markParentDamage();
      }
    }
    markParentDamage() {
      for (let cur = this; ; ) {
        let { parent } = cur;
        if (!parent || parent.damage & 1)
          break;
        parent.damage |= 1;
        cur = parent;
      }
    }
    get domAtom() {
      return false;
    }
    get ignoreForCoords() {
      return false;
    }
    get ignoreForSelection() {
      return false;
    }
    isText(text) {
      return false;
    }
  };
  var WidgetViewDesc = class extends ViewDesc {
    constructor(parent, widget, view, pos) {
      let self, dom = widget.type.toDOM;
      if (typeof dom == "function")
        dom = dom(view, () => {
          if (!self)
            return pos;
          if (self.parent)
            return self.parent.posBeforeChild(self);
        });
      if (!widget.type.spec.raw) {
        let elt = isElt(dom) ? dom : document.createElement("span");
        if (elt != dom) {
          elt.appendChild(dom);
          dom = elt;
        }
        if (!elt.hasAttribute("contenteditable"))
          elt.contentEditable = "false";
        elt.classList.add("ProseMirror-widget");
      }
      super(parent, [], dom, null);
      this.widget = widget;
      this.widget = widget;
      self = this;
    }
    matchesWidget(widget) {
      return !this.damage && widget.type.eq(this.widget.type);
    }
    parseRule() {
      return { ignore: true };
    }
    stopEvent(event) {
      let stop = this.widget.spec.stopEvent;
      return stop ? stop(event) : false;
    }
    ignoreMutation(mutation) {
      return mutation.type != "selection" || this.widget.spec.ignoreSelection;
    }
    destroy() {
      this.widget.type.destroy(this.dom);
      super.destroy();
    }
    get domAtom() {
      return true;
    }
    get ignoreForSelection() {
      return !!this.widget.type.spec.relaxedSide;
    }
    get side() {
      return this.widget.type.side;
    }
  };
  var CompositionViewDesc = class extends ViewDesc {
    constructor(parent, dom, textDOM, text) {
      super(parent, [], dom, null);
      this.textDOM = textDOM;
      this.text = text;
    }
    get size() {
      return this.text.length;
    }
    localPosFromDOM(dom, offset) {
      if (dom != this.textDOM)
        return this.posAtStart + (offset ? this.size : 0);
      return this.posAtStart + offset;
    }
    domFromPos(pos) {
      return { node: this.textDOM, offset: pos };
    }
    ignoreMutation(mut) {
      return mut.type === "characterData" && mut.target.nodeValue == mut.oldValue;
    }
  };
  var MarkViewDesc = class _MarkViewDesc extends ViewDesc {
    constructor(parent, mark, dom, contentDOM, spec) {
      super(parent, [], dom, contentDOM);
      this.mark = mark;
      this.spec = spec;
    }
    static create(parent, mark, inline, view) {
      let custom = view.nodeViews[mark.type.name];
      let spec = custom && custom(mark, view, inline);
      if (!spec || !spec.dom)
        spec = DOMSerializer.renderSpec(document, mark.type.spec.toDOM(mark, inline), null, mark.attrs);
      return new _MarkViewDesc(parent, mark, spec.dom, spec.contentDOM || spec.dom, spec);
    }
    parseRule() {
      if (this.damage & 4 || this.mark.type.spec.reparseInView)
        return null;
      return { mark: this.mark.type.name, attrs: this.mark.attrs, contentElement: this.contentDOM };
    }
    matchesMark(mark) {
      return !(this.damage & 4) && this.mark.eq(mark);
    }
    markDamage(damage) {
      var _a;
      this.damage |= damage;
      (_a = this.parent) === null || _a === void 0 ? void 0 : _a.markDamage(
        2
        /* Damage.ChildList */
      );
    }
    slice(from2, to, view) {
      let copy2 = _MarkViewDesc.create(this.parent, this.mark, true, view);
      let nodes2 = this.children, size = this.size;
      if (to < size)
        nodes2 = replaceNodes(nodes2, to, size, view);
      if (from2 > 0)
        nodes2 = replaceNodes(nodes2, 0, from2, view);
      for (let i = 0; i < nodes2.length; i++)
        nodes2[i].parent = copy2;
      copy2.children = nodes2;
      return copy2;
    }
    ignoreMutation(mutation) {
      return this.spec.ignoreMutation ? this.spec.ignoreMutation(mutation) : super.ignoreMutation(mutation);
    }
    destroy() {
      if (this.spec.destroy)
        this.spec.destroy();
      super.destroy();
    }
  };
  var NodeViewDesc = class _NodeViewDesc extends ViewDesc {
    constructor(parent, node, outerDeco, innerDeco, dom, contentDOM, nodeDOM) {
      super(parent, [], dom, contentDOM);
      this.node = node;
      this.outerDeco = outerDeco;
      this.innerDeco = innerDeco;
      this.nodeDOM = nodeDOM;
    }
    // By default, a node is rendered using the `toDOM` method from the
    // node type spec. But client code can use the `nodeViews` spec to
    // supply a custom node view, which can influence various aspects of
    // the way the node works.
    //
    // (Using subclassing for this was intentionally decided against,
    // since it'd require exposing a whole slew of finicky
    // implementation details to the user code that they probably will
    // never need.)
    static create(parent, node, outerDeco, innerDeco, view, pos) {
      let custom = view.nodeViews[node.type.name], descObj;
      let spec = custom && custom(node, view, () => {
        if (!descObj)
          return pos;
        if (descObj.parent)
          return descObj.parent.posBeforeChild(descObj);
      }, outerDeco, innerDeco);
      let dom = spec && spec.dom, contentDOM = spec && spec.contentDOM;
      if (node.isText) {
        if (!dom)
          dom = document.createTextNode(node.text);
        else if (!isText(dom))
          throw new RangeError("Text must be rendered as a DOM text node");
      } else if (!dom) {
        let spec2 = DOMSerializer.renderSpec(document, node.type.spec.toDOM(node), null, node.attrs);
        ({ dom, contentDOM } = spec2);
      }
      if (!contentDOM && !node.isText && dom.nodeName != "BR") {
        if (!dom.hasAttribute("contenteditable"))
          dom.contentEditable = "false";
        if (node.type.spec.draggable)
          dom.draggable = true;
      }
      let nodeDOM = dom;
      dom = applyOuterDeco(dom, outerDeco, node);
      if (spec)
        return descObj = new CustomNodeViewDesc(parent, node, outerDeco, innerDeco, dom, contentDOM || null, nodeDOM, spec);
      else if (node.isText)
        return new TextViewDesc(parent, node, outerDeco, innerDeco, dom, nodeDOM);
      else
        return new _NodeViewDesc(parent, node, outerDeco, innerDeco, dom, contentDOM || null, nodeDOM);
    }
    parseRule(addedNodes) {
      if (this.node.type.spec.reparseInView)
        return null;
      let rule = { node: this.node.type.name, attrs: this.node.attrs };
      if (this.node.type.whitespace == "pre")
        rule.preserveWhitespace = "full";
      if (!this.contentDOM) {
        rule.getContent = () => this.node.content;
      } else if (!this.contentLost) {
        rule.contentElement = this.contentDOM;
      } else {
        for (let i = this.children.length - 1; i >= 0; i--) {
          let child = this.children[i];
          if (this.dom.contains(child.dom.parentNode)) {
            rule.contentElement = child.dom.parentNode;
            break;
          }
        }
        if (!rule.contentElement) {
          let found2 = addedNodes && addedNodes.find((n) => isElt(n) && addedNodes.indexOf(n.parentNode) < 0 && this.dom.contains(n));
          if (found2)
            rule.contentElement = found2;
          else
            rule.getContent = () => Fragment.empty;
        }
      }
      return rule;
    }
    matchesNode(node, outerDeco, innerDeco) {
      return !this.damage && node.eq(this.node) && sameOuterDeco(outerDeco, this.outerDeco) && innerDeco.eq(this.innerDeco);
    }
    get size() {
      return this.node.nodeSize;
    }
    get border() {
      return this.node.isLeaf ? 0 : 1;
    }
    // Syncs `this.children` to match `this.node.content` and the local
    // decorations, possibly introducing nesting for marks. Then, in a
    // separate step, syncs the DOM inside `this.contentDOM` to
    // `this.children`.
    updateChildren(view, pos) {
      let inline = this.node.inlineContent, off = pos;
      let composition = view.composing ? this.localCompositionInfo(view, pos) : null;
      let localComposition = composition && composition.pos > -1 ? composition : null;
      let compositionInChild = composition && composition.pos < 0;
      let updater = new ViewTreeUpdater(this, localComposition && localComposition.node, view);
      let addBuffers = this.node.inlineContent, atBufferPos = addBuffers && this.node.isBlock;
      iterDeco(this.node, this.innerDeco, (widget, i, insideNode) => {
        if (widget.spec.marks)
          updater.syncToMarks(widget.spec.marks, inline, view, i);
        else if (widget.type.side >= 0 && !insideNode)
          updater.syncToMarks(i == this.node.childCount ? Mark.none : this.node.child(i).marks, inline, view, i);
        updater.placeWidget(widget, view, off);
      }, (child, outerDeco, innerDeco, i) => {
        updater.syncToMarks(child.marks, inline, view, i);
        if (atBufferPos && child.isAtom && !child.isText)
          updater.addHackNode("WBR", updater.top);
        let compIndex;
        if (updater.findNodeMatch(child, outerDeco, innerDeco, i)) ;
        else if (compositionInChild && view.state.selection.from > off && view.state.selection.to < off + child.nodeSize && (compIndex = updater.findIndexWithChild(composition.node)) > -1 && updater.updateNodeAt(child, outerDeco, innerDeco, compIndex, view, off)) ;
        else if (updater.updateNextNode(child, outerDeco, innerDeco, view, i, off)) ;
        else {
          updater.addNode(child, outerDeco, innerDeco, view, off);
        }
        off += child.nodeSize;
        if (addBuffers)
          atBufferPos = child.isAtom && !child.isText;
      });
      updater.syncToMarks([], inline, view, 0);
      if (this.node.isTextblock)
        updater.addTextblockHacks();
      updater.destroyRest();
      if (updater.changed || this.damage & 2) {
        if (localComposition)
          this.protectLocalComposition(view, localComposition);
        renderDescs(this.contentDOM, this.children, view);
        if (ios)
          iosHacks(this.dom);
      }
    }
    localCompositionInfo(view, pos) {
      let { from: from2, to } = view.state.selection;
      if (!(view.state.selection instanceof TextSelection) || from2 < pos || to > pos + this.node.content.size)
        return null;
      let textNode = view.input.compositionNode;
      if (!textNode || !this.dom.contains(textNode.parentNode))
        return null;
      if (this.node.inlineContent) {
        let text = textNode.nodeValue;
        let textPos = findTextInFragment(this.node.content, text, from2 - pos, to - pos);
        return textPos < 0 ? null : { node: textNode, pos: textPos, text };
      } else {
        return { node: textNode, pos: -1, text: "" };
      }
    }
    protectLocalComposition(view, { node, pos, text }) {
      if (this.getDesc(node))
        return;
      let topNode = node;
      for (; ; topNode = topNode.parentNode) {
        if (topNode.parentNode == this.contentDOM)
          break;
        while (topNode.previousSibling)
          topNode.parentNode.removeChild(topNode.previousSibling);
        while (topNode.nextSibling)
          topNode.parentNode.removeChild(topNode.nextSibling);
        if (topNode.pmViewDesc)
          topNode.pmViewDesc = void 0;
      }
      let desc = new CompositionViewDesc(this, topNode, node, text);
      view.input.compositionNodes.push(desc);
      this.children = replaceNodes(this.children, pos, pos + text.length, view, desc);
    }
    // If this desc must be updated to match the given node decoration,
    // do so and return true. pos is the position before the node, or -1
    // for the document.
    update(node, outerDeco, innerDeco, view, pos) {
      if (this.damage & 4 || !node.sameMarkup(this.node))
        return false;
      this.updateInner(node, outerDeco, innerDeco, view, pos);
      return true;
    }
    updateInner(node, outerDeco, innerDeco, view, pos) {
      this.updateOuterDeco(outerDeco);
      this.node = node;
      this.innerDeco = innerDeco;
      if (this.contentDOM)
        this.updateChildren(view, pos + 1);
      this.damage = 0;
    }
    updateOuterDeco(outerDeco) {
      if (sameOuterDeco(outerDeco, this.outerDeco))
        return;
      let needsWrap = !isElt(this.nodeDOM);
      let oldDOM = this.dom;
      this.dom = patchOuterDeco(this.dom, this.nodeDOM, computeOuterDeco(this.outerDeco, this.node, needsWrap), computeOuterDeco(outerDeco, this.node, needsWrap));
      if (this.dom != oldDOM) {
        oldDOM.pmViewDesc = void 0;
        this.dom.pmViewDesc = this;
      }
      this.outerDeco = outerDeco;
    }
    // Mark this node as being the selected node.
    selectNode() {
      if (isElt(this.nodeDOM)) {
        this.nodeDOM.classList.add("ProseMirror-selectednode");
        if (this.contentDOM || !this.node.type.spec.draggable)
          this.nodeDOM.draggable = true;
      }
    }
    // Remove selected node marking from this node.
    deselectNode() {
      if (isElt(this.nodeDOM)) {
        this.nodeDOM.classList.remove("ProseMirror-selectednode");
        if (this.contentDOM || !this.node.type.spec.draggable)
          this.nodeDOM.removeAttribute("draggable");
      }
    }
    get domAtom() {
      return this.node.isAtom;
    }
  };
  function docViewDesc(doc3, outerDeco, innerDeco, dom, view, prevOuterDeco) {
    if (!prevOuterDeco)
      applyOuterDeco(dom, outerDeco, doc3);
    else
      patchOuterDeco(dom, dom, computeOuterDeco(prevOuterDeco, doc3, false), computeOuterDeco(outerDeco, doc3, false));
    let docView = new NodeViewDesc(void 0, doc3, outerDeco, innerDeco, dom, dom, dom);
    if (docView.contentDOM)
      docView.updateChildren(view, 0);
    return docView;
  }
  var TextViewDesc = class _TextViewDesc extends NodeViewDesc {
    constructor(parent, node, outerDeco, innerDeco, dom, nodeDOM) {
      super(parent, node, outerDeco, innerDeco, dom, null, nodeDOM);
    }
    parseRule() {
      let skip = this.nodeDOM.parentNode;
      while (skip && skip != this.dom && !skip.pmIsDeco)
        skip = skip.parentNode;
      return { skip: skip || true };
    }
    update(node, outerDeco, innerDeco, view) {
      if (this.damage & 4 || this.damage && !this.inParent() || !node.sameMarkup(this.node))
        return false;
      this.updateOuterDeco(outerDeco);
      if ((this.damage & 8 || node.text != this.node.text) && node.text != this.nodeDOM.nodeValue) {
        this.nodeDOM.nodeValue = node.text;
        if (view.trackWrites == this.nodeDOM)
          view.trackWrites = null;
      }
      this.node = node;
      this.damage = 0;
      return true;
    }
    inParent() {
      let parentDOM = this.parent.contentDOM;
      for (let n = this.nodeDOM; n; n = n.parentNode)
        if (n == parentDOM)
          return true;
      return false;
    }
    domFromPos(pos) {
      return { node: this.nodeDOM, offset: pos };
    }
    localPosFromDOM(dom, offset, bias) {
      if (dom == this.nodeDOM)
        return this.posAtStart + Math.min(offset, this.node.text.length);
      return super.localPosFromDOM(dom, offset, bias);
    }
    ignoreMutation(mutation) {
      return false;
    }
    slice(from2, to, _view) {
      let node = this.node.cut(from2, to), dom = document.createTextNode(node.text);
      return new _TextViewDesc(this.parent, node, this.outerDeco, this.innerDeco, dom, dom);
    }
    get domAtom() {
      return false;
    }
    isText(text) {
      return this.node.text == text;
    }
  };
  var BufferHackViewDesc = class extends ViewDesc {
    parseRule() {
      return { ignore: true };
    }
    matchesHack(nodeName) {
      return !this.damage && this.dom.nodeName == nodeName;
    }
    get domAtom() {
      return true;
    }
    get ignoreForCoords() {
      return this.dom.nodeName == "WBR";
    }
  };
  var CustomNodeViewDesc = class extends NodeViewDesc {
    constructor(parent, node, outerDeco, innerDeco, dom, contentDOM, nodeDOM, spec) {
      super(parent, node, outerDeco, innerDeco, dom, contentDOM, nodeDOM);
      this.spec = spec;
    }
    // A custom `update` method gets to decide whether the update goes
    // through. If it does, and there's a `contentDOM` node, our logic
    // updates the children.
    update(node, outerDeco, innerDeco, view, pos) {
      if (this.damage & 4)
        return false;
      if (this.spec.update && (this.node.type == node.type || this.spec.multiType)) {
        let result = this.spec.update(node, outerDeco, innerDeco);
        if (result)
          this.updateInner(node, outerDeco, innerDeco, view, pos);
        return result;
      } else if (!this.contentDOM && !node.isLeaf) {
        return false;
      } else {
        return super.update(node, outerDeco, innerDeco, view, pos);
      }
    }
    selectNode() {
      this.spec.selectNode ? this.spec.selectNode() : super.selectNode();
    }
    deselectNode() {
      this.spec.deselectNode ? this.spec.deselectNode() : super.deselectNode();
    }
    destroy() {
      if (this.spec.destroy)
        this.spec.destroy();
      super.destroy();
    }
    stopEvent(event) {
      return this.spec.stopEvent ? this.spec.stopEvent(event) : false;
    }
    ignoreMutation(mutation) {
      return this.spec.ignoreMutation ? this.spec.ignoreMutation(mutation) : super.ignoreMutation(mutation);
    }
  };
  function renderDescs(parentDOM, descs, view) {
    let dom = parentDOM.firstChild, written = false;
    for (let i = 0; i < descs.length; i++) {
      let desc = descs[i], childDOM = desc.dom;
      if (childDOM.parentNode == parentDOM) {
        while (childDOM != dom) {
          dom = rm(dom);
          written = true;
        }
        dom = dom.nextSibling;
      } else {
        written = true;
        parentDOM.insertBefore(childDOM, dom);
      }
      if (desc instanceof MarkViewDesc) {
        let pos = dom ? dom.previousSibling : parentDOM.lastChild;
        renderDescs(desc.contentDOM, desc.children, view);
        dom = pos ? pos.nextSibling : parentDOM.firstChild;
      }
    }
    while (dom) {
      dom = rm(dom);
      written = true;
    }
    if (written && view.trackWrites == parentDOM)
      view.trackWrites = null;
  }
  var OuterDecoLevel = function(nodeName) {
    if (nodeName)
      this.nodeName = nodeName;
  };
  OuterDecoLevel.prototype = /* @__PURE__ */ Object.create(null);
  var noDeco = [new OuterDecoLevel()];
  function computeOuterDeco(outerDeco, node, needsWrap) {
    if (outerDeco.length == 0)
      return noDeco;
    let top = needsWrap ? noDeco[0] : new OuterDecoLevel(), result = [top];
    for (let i = 0; i < outerDeco.length; i++) {
      let attrs = outerDeco[i].type.attrs;
      if (!attrs)
        continue;
      if (attrs.nodeName)
        result.push(top = new OuterDecoLevel(attrs.nodeName));
      for (let name in attrs) {
        let val = attrs[name];
        if (val == null)
          continue;
        if (needsWrap && result.length == 1)
          result.push(top = new OuterDecoLevel(node.isInline ? "span" : "div"));
        if (name == "class")
          top.class = (top.class ? top.class + " " : "") + val;
        else if (name == "style")
          top.style = (top.style ? top.style + ";" : "") + val;
        else if (name != "nodeName")
          top[name] = val;
      }
    }
    return result;
  }
  function patchOuterDeco(outerDOM, nodeDOM, prevComputed, curComputed) {
    if (prevComputed == noDeco && curComputed == noDeco)
      return nodeDOM;
    let curDOM = nodeDOM;
    for (let i = 0; i < curComputed.length; i++) {
      let deco = curComputed[i], prev = prevComputed[i];
      if (i) {
        let parent;
        if (prev && prev.nodeName == deco.nodeName && curDOM != outerDOM && (parent = curDOM.parentNode) && parent.nodeName.toLowerCase() == deco.nodeName) {
          curDOM = parent;
        } else {
          parent = document.createElement(deco.nodeName);
          parent.pmIsDeco = true;
          parent.appendChild(curDOM);
          prev = noDeco[0];
          curDOM = parent;
        }
      }
      patchAttributes(curDOM, prev || noDeco[0], deco);
    }
    return curDOM;
  }
  function patchAttributes(dom, prev, cur) {
    for (let name in prev)
      if (name != "class" && name != "style" && name != "nodeName" && !(name in cur))
        dom.removeAttribute(name);
    for (let name in cur)
      if (name != "class" && name != "style" && name != "nodeName" && cur[name] != prev[name])
        dom.setAttribute(name, cur[name]);
    if (prev.class != cur.class) {
      let prevList = prev.class ? prev.class.split(" ").filter(Boolean) : [];
      let curList = cur.class ? cur.class.split(" ").filter(Boolean) : [];
      for (let i = 0; i < prevList.length; i++)
        if (curList.indexOf(prevList[i]) == -1)
          dom.classList.remove(prevList[i]);
      for (let i = 0; i < curList.length; i++)
        if (prevList.indexOf(curList[i]) == -1)
          dom.classList.add(curList[i]);
      if (dom.classList.length == 0)
        dom.removeAttribute("class");
    }
    if (prev.style != cur.style) {
      if (prev.style) {
        let prop = /\s*([\w\-\xa1-\uffff]+)\s*:(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|\(.*?\)|[^;])*/g, m;
        while (m = prop.exec(prev.style))
          dom.style.removeProperty(m[1]);
      }
      if (cur.style)
        dom.style.cssText += cur.style;
    }
  }
  function applyOuterDeco(dom, deco, node) {
    return patchOuterDeco(dom, dom, noDeco, computeOuterDeco(deco, node, !isElt(dom)));
  }
  function sameOuterDeco(a, b) {
    if (a.length != b.length)
      return false;
    for (let i = 0; i < a.length; i++)
      if (!a[i].type.eq(b[i].type))
        return false;
    return true;
  }
  function rm(dom) {
    let next = dom.nextSibling;
    dom.parentNode.removeChild(dom);
    return next;
  }
  var ViewTreeUpdater = class {
    constructor(top, lock, view) {
      this.lock = lock;
      this.view = view;
      this.index = 0;
      this.stack = [];
      this.changed = false;
      this.top = top;
      this.preMatch = preMatch(top.node.content, top);
    }
    // Destroy and remove the children between the given indices in
    // `this.top`.
    destroyBetween(start, end) {
      if (start == end)
        return;
      for (let i = start; i < end; i++)
        this.top.children[i].destroy();
      this.top.children.splice(start, end - start);
      this.changed = true;
    }
    // Destroy all remaining children in `this.top`.
    destroyRest() {
      this.destroyBetween(this.index, this.top.children.length);
    }
    // Sync the current stack of mark descs with the given array of
    // marks, reusing existing mark descs when possible.
    syncToMarks(marks2, inline, view, parentIndex) {
      let keep = 0, depth = this.stack.length >> 1;
      let maxKeep = Math.min(depth, marks2.length);
      while (keep < maxKeep && (keep == depth - 1 ? this.top : this.stack[keep + 1 << 1]).matchesMark(marks2[keep]) && marks2[keep].type.spec.spanning !== false)
        keep++;
      while (keep < depth) {
        this.destroyRest();
        this.top.damage = 0;
        this.index = this.stack.pop();
        this.top = this.stack.pop();
        depth--;
      }
      while (depth < marks2.length) {
        this.stack.push(this.top, this.index + 1);
        let found2 = -1, scanTo = this.top.children.length;
        if (parentIndex < this.preMatch.index)
          scanTo = Math.min(this.index + 3, scanTo);
        for (let i = this.index; i < scanTo; i++) {
          let next = this.top.children[i];
          if (next.matchesMark(marks2[depth]) && !this.isLocked(next.dom)) {
            found2 = i;
            break;
          }
        }
        if (found2 < 0 && this.index < this.top.children.length) {
          let cur = this.top.children[this.index];
          if (cur instanceof MarkViewDesc && !(cur.damage & 4) && cur.mark.type == marks2[depth].type && cur.spec.update && !this.isLocked(cur.dom) && cur.spec.update(marks2[depth])) {
            cur.mark = marks2[depth];
            found2 = this.index;
            this.changed = true;
          }
        }
        if (found2 > -1) {
          if (found2 > this.index) {
            this.changed = true;
            this.destroyBetween(this.index, found2);
          }
          this.top = this.top.children[this.index];
        } else {
          let markDesc = MarkViewDesc.create(this.top, marks2[depth], inline, view);
          this.top.children.splice(this.index, 0, markDesc);
          this.top = markDesc;
          this.changed = true;
        }
        this.index = 0;
        depth++;
      }
    }
    // Try to find a node desc matching the given data. Skip over it and
    // return true when successful.
    findNodeMatch(node, outerDeco, innerDeco, index) {
      let found2 = -1, targetDesc;
      if (index >= this.preMatch.index && (targetDesc = this.preMatch.matches[index - this.preMatch.index]).parent == this.top && targetDesc.matchesNode(node, outerDeco, innerDeco)) {
        found2 = this.top.children.indexOf(targetDesc, this.index);
      } else {
        for (let i = this.index, e = Math.min(this.top.children.length, i + 5); i < e; i++) {
          let child = this.top.children[i];
          if (child.matchesNode(node, outerDeco, innerDeco) && !this.preMatch.matched.has(child)) {
            found2 = i;
            break;
          }
        }
      }
      if (found2 < 0)
        return false;
      this.destroyBetween(this.index, found2);
      this.index++;
      return true;
    }
    updateNodeAt(node, outerDeco, innerDeco, index, view, pos) {
      let child = this.top.children[index];
      if (child.damage & 4 && child.dom == child.contentDOM)
        child.damage = 2;
      if (!child.update(node, outerDeco, innerDeco, view, pos))
        return false;
      this.destroyBetween(this.index, index);
      this.index++;
      return true;
    }
    findIndexWithChild(domNode) {
      for (; ; ) {
        let parent = domNode.parentNode;
        if (!parent)
          return -1;
        if (parent == this.top.contentDOM) {
          let desc = domNode.pmViewDesc;
          if (desc)
            for (let i = this.index; i < this.top.children.length; i++) {
              if (this.top.children[i] == desc)
                return i;
            }
          return -1;
        }
        domNode = parent;
      }
    }
    // Try to update the next node, if any, to the given data. Checks
    // pre-matches to avoid overwriting nodes that could still be used.
    updateNextNode(node, outerDeco, innerDeco, view, index, pos) {
      for (let i = this.index; i < this.top.children.length; i++) {
        let next = this.top.children[i];
        if (next instanceof NodeViewDesc) {
          let preMatch2 = this.preMatch.matched.get(next);
          if (preMatch2 != null && preMatch2 != index)
            return false;
          let nextDOM = next.dom, updated;
          let locked = this.isLocked(nextDOM) && !(node.isText && next.node && next.node.isText && next.nodeDOM.nodeValue == node.text && !(next.damage & 4) && sameOuterDeco(outerDeco, next.outerDeco));
          if (!locked && next.update(node, outerDeco, innerDeco, view, pos)) {
            this.destroyBetween(this.index, i);
            if (next.dom != nextDOM)
              this.changed = true;
            this.index++;
            return true;
          } else if (!locked && (updated = this.recreateWrapper(next, node, outerDeco, innerDeco, view, pos))) {
            this.destroyBetween(this.index, i);
            this.top.children[this.index] = updated;
            if (updated.contentDOM) {
              updated.damage |= 2;
              updated.updateChildren(view, pos + 1);
              updated.damage = 0;
            }
            this.changed = true;
            this.index++;
            return true;
          }
          break;
        }
      }
      return false;
    }
    // When a node with content is replaced by a different node with
    // identical content, move over its children.
    recreateWrapper(next, node, outerDeco, innerDeco, view, pos) {
      if (next.damage & (2 | 1) || node.isAtom || !next.children.length || !next.node.content.eq(node.content) || !sameOuterDeco(outerDeco, next.outerDeco) || !innerDeco.eq(next.innerDeco))
        return null;
      let wrapper = NodeViewDesc.create(this.top, node, outerDeco, innerDeco, view, pos);
      if (wrapper.contentDOM) {
        wrapper.children = next.children;
        next.children = [];
        for (let ch of wrapper.children)
          ch.parent = wrapper;
      }
      next.destroy();
      return wrapper;
    }
    // Insert the node as a newly created node desc.
    addNode(node, outerDeco, innerDeco, view, pos) {
      let desc = NodeViewDesc.create(this.top, node, outerDeco, innerDeco, view, pos);
      if (desc.contentDOM)
        desc.updateChildren(view, pos + 1);
      this.top.children.splice(this.index++, 0, desc);
      this.changed = true;
    }
    placeWidget(widget, view, pos) {
      let next = this.index < this.top.children.length ? this.top.children[this.index] : null;
      if (next && next.matchesWidget(widget) && (widget == next.widget || !next.widget.type.toDOM.parentNode)) {
        this.index++;
      } else {
        let desc = new WidgetViewDesc(this.top, widget, view, pos);
        this.top.children.splice(this.index++, 0, desc);
        this.changed = true;
      }
    }
    // Make sure a textblock looks and behaves correctly in
    // contentEditable.
    addTextblockHacks() {
      let lastChild = this.top.children[this.index - 1], parent = this.top;
      while (lastChild instanceof MarkViewDesc) {
        parent = lastChild;
        lastChild = parent.children[parent.children.length - 1];
      }
      if (!lastChild || // Empty textblock
      !(lastChild instanceof TextViewDesc) || /\n$/.test(lastChild.node.text) || this.view.requiresGeckoHackNode && /\s$/.test(lastChild.node.text)) {
        if ((safari || chrome) && lastChild && lastChild.dom.contentEditable == "false")
          this.addHackNode("WBR", parent);
        this.addHackNode("BR", this.top);
      }
    }
    addHackNode(nodeName, parent) {
      if (parent == this.top && this.index < parent.children.length && parent.children[this.index].matchesHack(nodeName)) {
        this.index++;
      } else {
        let dom = document.createElement(nodeName);
        if (nodeName == "WBR") {
          dom.className = "ProseMirror-separator";
          dom.alt = "";
        }
        if (nodeName == "BR")
          dom.className = "ProseMirror-trailingBreak";
        let hack = new BufferHackViewDesc(this.top, [], dom, null);
        if (parent != this.top)
          parent.children.push(hack);
        else
          parent.children.splice(this.index++, 0, hack);
        this.changed = true;
      }
    }
    isLocked(node) {
      return this.lock && (node == this.lock || isElt(node) && node.contains(this.lock.parentNode));
    }
  };
  function preMatch(frag, parentDesc) {
    let curDesc = parentDesc, descI = curDesc.children.length, stack = [];
    let fI = frag.childCount, matched = /* @__PURE__ */ new Map(), matches2 = [];
    outer: while (fI > 0) {
      let desc;
      for (; ; ) {
        if (descI) {
          let next = curDesc.children[descI - 1];
          if (next instanceof MarkViewDesc) {
            stack.push(descI - 1);
            curDesc = next;
            descI = next.children.length;
          } else {
            desc = next;
            descI--;
            break;
          }
        } else if (curDesc == parentDesc) {
          break outer;
        } else {
          descI = stack.pop();
          curDesc = curDesc.parent;
        }
      }
      let node = desc.node;
      if (!node)
        continue;
      if (node != frag.child(fI - 1))
        break;
      --fI;
      matched.set(desc, fI);
      matches2.push(desc);
    }
    return { index: fI, matched, matches: matches2.reverse() };
  }
  function compareSide(a, b) {
    return a.type.side - b.type.side;
  }
  function iterDeco(parent, deco, onWidget, onNode) {
    let locals = deco.locals(parent), offset = 0;
    if (locals.length == 0) {
      for (let i = 0; i < parent.childCount; i++) {
        let child = parent.child(i);
        onNode(child, locals, deco.forChild(offset, child), i);
        offset += child.nodeSize;
      }
      return;
    }
    let decoIndex = 0, active = [], restNode = null;
    for (let parentIndex = 0; ; ) {
      let widget, widgets;
      while (decoIndex < locals.length && locals[decoIndex].to == offset) {
        let next = locals[decoIndex++];
        if (next.widget) {
          if (!widget)
            widget = next;
          else
            (widgets || (widgets = [widget])).push(next);
        }
      }
      if (widget) {
        if (widgets) {
          widgets.sort(compareSide);
          for (let i = 0; i < widgets.length; i++)
            onWidget(widgets[i], parentIndex, !!restNode);
        } else {
          onWidget(widget, parentIndex, !!restNode);
        }
      }
      let child, index;
      if (restNode) {
        index = -1;
        child = restNode;
        restNode = null;
      } else if (parentIndex < parent.childCount) {
        index = parentIndex;
        child = parent.child(parentIndex++);
      } else {
        break;
      }
      for (let i = 0; i < active.length; i++)
        if (active[i].to <= offset)
          active.splice(i--, 1);
      while (decoIndex < locals.length && locals[decoIndex].from <= offset && locals[decoIndex].to > offset)
        active.push(locals[decoIndex++]);
      let end = offset + child.nodeSize;
      if (child.isText) {
        let cutAt = end;
        if (decoIndex < locals.length && locals[decoIndex].from < cutAt)
          cutAt = locals[decoIndex].from;
        for (let i = 0; i < active.length; i++)
          if (active[i].to < cutAt)
            cutAt = active[i].to;
        if (cutAt < end) {
          restNode = child.cut(cutAt - offset);
          child = child.cut(0, cutAt - offset);
          end = cutAt;
          index = -1;
        }
      } else {
        while (decoIndex < locals.length && locals[decoIndex].to < end)
          decoIndex++;
      }
      let outerDeco = child.isInline && !child.isLeaf ? active.filter((d) => !d.inline) : active.slice();
      onNode(child, outerDeco, deco.forChild(offset, child), index);
      offset = end;
    }
  }
  function iosHacks(dom) {
    if (dom.nodeName == "UL" || dom.nodeName == "OL") {
      let oldCSS = dom.style.cssText;
      dom.style.cssText = oldCSS + "; list-style: square !important";
      window.getComputedStyle(dom).listStyle;
      dom.style.cssText = oldCSS;
    }
  }
  function findTextInFragment(frag, text, from2, to) {
    for (let i = 0, pos = 0; i < frag.childCount && pos <= to; ) {
      let child = frag.child(i++), childStart = pos;
      pos += child.nodeSize;
      if (!child.isText)
        continue;
      let str = child.text;
      while (i < frag.childCount) {
        let next = frag.child(i++);
        pos += next.nodeSize;
        if (!next.isText)
          break;
        str += next.text;
      }
      if (pos >= from2) {
        if (pos >= to && str.slice(to - text.length - childStart, to - childStart) == text)
          return to - text.length;
        let found2 = childStart < to ? str.lastIndexOf(text, to - childStart - 1) : -1;
        if (found2 >= 0 && found2 + text.length + childStart >= from2)
          return childStart + found2;
        if (from2 == to && str.length >= to + text.length - childStart && str.slice(to - childStart, to - childStart + text.length) == text)
          return to;
      }
    }
    return -1;
  }
  function replaceNodes(nodes2, from2, to, view, replacement) {
    let result = [];
    for (let i = 0, off = 0; i < nodes2.length; i++) {
      let child = nodes2[i], start = off, end = off += child.size;
      if (start >= to || end <= from2) {
        result.push(child);
      } else {
        if (start < from2)
          result.push(child.slice(0, from2 - start, view));
        if (replacement) {
          result.push(replacement);
          replacement = void 0;
        }
        if (end > to)
          result.push(child.slice(to - start, child.size, view));
      }
    }
    return result;
  }
  function moveSelectionBlock(state, dir) {
    let { $anchor, $head } = state.selection;
    let $side = dir > 0 ? $anchor.max($head) : $anchor.min($head);
    let $start = !$side.parent.inlineContent ? $side : $side.depth ? state.doc.resolve(dir > 0 ? $side.after() : $side.before()) : null;
    return $start && Selection.findFrom($start, dir);
  }
  function apply(view, sel) {
    view.dispatch(view.state.tr.setSelection(sel).scrollIntoView());
    return true;
  }
  function selectHorizontally(view, dir, mods) {
    let sel = view.state.selection;
    if (sel instanceof TextSelection) {
      if (mods.indexOf("s") > -1) {
        let { $head } = sel, node = $head.textOffset ? null : dir < 0 ? $head.nodeBefore : $head.nodeAfter;
        if (!node || node.isText || !node.isLeaf)
          return false;
        let $newHead = view.state.doc.resolve($head.pos + node.nodeSize * (dir < 0 ? -1 : 1));
        return apply(view, new TextSelection(sel.$anchor, $newHead));
      } else if (!sel.empty) {
        return false;
      } else if (view.endOfTextblock(dir > 0 ? "forward" : "backward")) {
        let next = moveSelectionBlock(view.state, dir);
        if (next && next instanceof NodeSelection)
          return apply(view, next);
        return false;
      } else if (!mac || mods.indexOf("m") < 0) {
        let $head = sel.$head, node = $head.textOffset ? null : dir < 0 ? $head.nodeBefore : $head.nodeAfter, desc;
        if (!node || node.isText)
          return false;
        let nodePos = dir < 0 ? $head.pos - node.nodeSize : $head.pos;
        if (!(node.isAtom || (desc = view.docView.descAt(nodePos)) && !desc.contentDOM))
          return false;
        if (NodeSelection.isSelectable(node)) {
          return apply(view, new NodeSelection(dir < 0 ? view.state.doc.resolve($head.pos - node.nodeSize) : $head));
        } else {
          return apply(view, new TextSelection(view.state.doc.resolve(dir < 0 ? nodePos : nodePos + node.nodeSize)));
        }
      }
    } else if (sel instanceof NodeSelection && sel.node.isInline) {
      return apply(view, new TextSelection(dir > 0 ? sel.$to : sel.$from));
    } else {
      let next = moveSelectionBlock(view.state, dir);
      if (next)
        return apply(view, next);
      return false;
    }
  }
  function isIgnorable(dom, dir) {
    let desc = dom.pmViewDesc;
    return desc ? desc.size == 0 && (dir < 0 || dom.nextSibling || dom.nodeName != "BR") : isElt(dom) && dom.contentEditable == "false";
  }
  function skipIgnoredNodes(view, dir) {
    return dir < 0 ? skipIgnoredNodesBefore(view) : skipIgnoredNodesAfter(view);
  }
  function skipIgnoredNodesBefore(view) {
    let sel = view.domSel.readRange();
    let node = sel.focusNode, offset = sel.focusOffset;
    if (!node)
      return;
    let moveNode, moveOffset, force = false;
    if (gecko && isElt(node) && offset < nodeSize(node) && isIgnorable(node.childNodes[offset], -1))
      force = true;
    for (; ; ) {
      if (offset > 0) {
        if (!isElt(node))
          break;
        let before = node.childNodes[offset - 1];
        if (isIgnorable(before, -1)) {
          moveNode = node;
          moveOffset = --offset;
        } else if (isText(before)) {
          node = before;
          offset = node.nodeValue.length;
        } else {
          break;
        }
      } else if (isBlockNode(node)) {
        break;
      } else {
        let prev = node.previousSibling;
        while (prev && isIgnorable(prev, -1)) {
          moveNode = node.parentNode;
          moveOffset = domIndex(prev);
          prev = prev.previousSibling;
        }
        if (!prev) {
          node = node.parentNode;
          if (node == view.dom)
            break;
          offset = 0;
        } else {
          node = prev;
          offset = nodeSize(node);
        }
      }
    }
    if (force)
      setSelFocus(view, node, offset);
    else if (moveNode)
      setSelFocus(view, moveNode, moveOffset);
  }
  function skipIgnoredNodesAfter(view) {
    let sel = view.domSel.readRange();
    let node = sel.focusNode, offset = sel.focusOffset;
    if (!node)
      return;
    let len = nodeSize(node);
    let moveNode, moveOffset;
    for (; ; ) {
      if (offset < len) {
        if (!isElt(node))
          break;
        let after = node.childNodes[offset];
        if (isIgnorable(after, 1)) {
          moveNode = node;
          moveOffset = ++offset;
        } else {
          break;
        }
      } else if (isBlockNode(node)) {
        break;
      } else {
        let next = node.nextSibling;
        while (next && isIgnorable(next, 1)) {
          moveNode = next.parentNode;
          moveOffset = domIndex(next) + 1;
          next = next.nextSibling;
        }
        if (!next) {
          node = node.parentNode;
          if (node == view.dom)
            break;
          offset = len = 0;
        } else {
          node = next;
          offset = 0;
          len = nodeSize(node);
        }
      }
    }
    if (moveNode)
      setSelFocus(view, moveNode, moveOffset);
  }
  function isBlockNode(dom) {
    for (let scan = dom; scan; scan = scan.parentNode) {
      let desc = scan.pmViewDesc;
      if (desc)
        return desc.node ? desc.node.isBlock : false;
    }
    return false;
  }
  function setSelFocus(view, node, offset) {
    if (!isText(node)) {
      let before, after;
      if (after = textNodeAfter(node, offset)) {
        node = after;
        offset = 0;
      } else if (before = textNodeBefore(node, offset)) {
        node = before;
        offset = before.nodeValue.length;
      }
    }
    let sel = view.domSelection(), range = view.domSel.readRange();
    if (!sel)
      return;
    if (selectionCollapsed(range)) {
      sel.collapse(node, offset);
    } else if (sel.extend) {
      sel.collapse(range.anchorNode, range.anchorOffset);
      sel.extend(node, offset);
    }
    view.domSel.ignore();
    let { state } = view;
    setTimeout(() => {
      if (view.state == state)
        view.domSel.sync();
    }, 50);
  }
  function findDirection(view, pos) {
    let $pos = view.state.doc.resolve(pos);
    if (!(chrome || windows) && $pos.parent.inlineContent) {
      let coords = view.coordsAtPos(pos);
      if (pos > $pos.start()) {
        let before = view.coordsAtPos(pos - 1);
        let mid = (before.top + before.bottom) / 2;
        if (mid > coords.top && mid < coords.bottom && Math.abs(before.left - coords.left) > 1)
          return before.left < coords.left ? "ltr" : "rtl";
      }
      if (pos < $pos.end()) {
        let after = view.coordsAtPos(pos + 1);
        let mid = (after.top + after.bottom) / 2;
        if (mid > coords.top && mid < coords.bottom && Math.abs(after.left - coords.left) > 1)
          return after.left > coords.left ? "ltr" : "rtl";
      }
    }
    let block = view.dom;
    for (let d = $pos.depth; d > 0; d--)
      if ($pos.node(d).isBlock) {
        block = view.nodeDOM($pos.before(d)) || block;
        break;
      }
    let computed = getComputedStyle(block).direction;
    return computed == "rtl" ? "rtl" : "ltr";
  }
  function selectVertically(view, dir, mods) {
    let sel = view.state.selection;
    if (sel instanceof TextSelection && !sel.empty || mods.indexOf("s") > -1)
      return false;
    if (mac && mods.indexOf("m") > -1)
      return false;
    let { $from, $to } = sel;
    if (!$from.parent.inlineContent || view.endOfTextblock(dir < 0 ? "up" : "down")) {
      let next = moveSelectionBlock(view.state, dir);
      if (next && next instanceof NodeSelection)
        return apply(view, next);
    }
    if (!$from.parent.inlineContent) {
      let side = dir < 0 ? $from : $to;
      let beyond = sel instanceof AllSelection ? Selection.near(side, dir) : Selection.findFrom(side, dir);
      return beyond ? apply(view, beyond) : false;
    }
    return false;
  }
  function stopNativeHorizontalDelete(view, dir) {
    if (!(view.state.selection instanceof TextSelection))
      return true;
    let { $head, $anchor, empty: empty2 } = view.state.selection;
    if (!$head.sameParent($anchor))
      return true;
    if (!empty2)
      return false;
    if (view.endOfTextblock(dir > 0 ? "forward" : "backward"))
      return true;
    let nextNode = !$head.textOffset && (dir < 0 ? $head.nodeBefore : $head.nodeAfter);
    if (nextNode && !nextNode.isText) {
      let tr = view.state.tr;
      if (dir < 0)
        tr.delete($head.pos - nextNode.nodeSize, $head.pos);
      else
        tr.delete($head.pos, $head.pos + nextNode.nodeSize);
      view.dispatch(tr);
      return true;
    }
    return false;
  }
  function switchEditable(view, node, state) {
    view.domObserver.stopped(() => node.contentEditable = state);
  }
  function safariDownArrowBug(view) {
    if (!safari || view.state.selection.$head.parentOffset > 0)
      return false;
    let { focusNode, focusOffset } = view.domSel.readRange();
    if (focusNode && isElt(focusNode) && focusOffset == 0 && focusNode.firstChild && isElt(focusNode.firstChild) && focusNode.firstChild.contentEditable == "false") {
      let child = focusNode.firstChild;
      switchEditable(view, child, "true");
      setTimeout(() => switchEditable(view, child, "false"), 20);
    }
    return false;
  }
  function getMods(event) {
    let result = "";
    if (event.ctrlKey)
      result += "c";
    if (event.metaKey)
      result += "m";
    if (event.altKey)
      result += "a";
    if (event.shiftKey)
      result += "s";
    return result;
  }
  function captureKeyDown(view, event) {
    let code = event.keyCode, mods = getMods(event);
    if (code == 8 || mac && code == 72 && mods == "c") {
      return stopNativeHorizontalDelete(view, -1) || skipIgnoredNodes(view, -1);
    } else if (code == 46 && !event.shiftKey || mac && code == 68 && mods == "c") {
      return stopNativeHorizontalDelete(view, 1) || skipIgnoredNodes(view, 1);
    } else if (code == 13 || code == 27) {
      return true;
    } else if (code == 37 || mac && code == 66 && mods == "c") {
      let dir = code == 37 ? findDirection(view, view.state.selection.from) == "ltr" ? -1 : 1 : -1;
      return selectHorizontally(view, dir, mods) || skipIgnoredNodes(view, dir);
    } else if (code == 39 || mac && code == 70 && mods == "c") {
      let dir = code == 39 ? findDirection(view, view.state.selection.from) == "ltr" ? 1 : -1 : 1;
      return selectHorizontally(view, dir, mods) || skipIgnoredNodes(view, dir);
    } else if (code == 38 || mac && code == 80 && mods == "c") {
      return selectVertically(view, -1, mods) || skipIgnoredNodes(view, -1);
    } else if (code == 40 || mac && code == 78 && mods == "c") {
      return safariDownArrowBug(view) || selectVertically(view, 1, mods) || skipIgnoredNodes(view, 1);
    } else if (mods == (mac ? "m" : "c") && (code == 66 || code == 73 || code == 89 || code == 90)) {
      return true;
    }
    return false;
  }
  function serializeForClipboard(view, slice2) {
    view.someProp("transformCopied", (f) => {
      slice2 = f(slice2, view);
    });
    let context = [], { content, openStart, openEnd } = slice2;
    while (openStart > 1 && openEnd > 1 && content.childCount == 1 && content.firstChild.childCount == 1) {
      openStart--;
      openEnd--;
      let node = content.firstChild;
      context.push(node.type.name, node.attrs != node.type.defaultAttrs ? node.attrs : null);
      content = node.content;
    }
    let serializer = view.someProp("clipboardSerializer") || DOMSerializer.fromSchema(view.state.schema);
    let doc3 = detachedDoc(), wrap2 = doc3.createElement("div");
    wrap2.appendChild(serializer.serializeFragment(content, { document: doc3 }));
    let firstChild = wrap2.firstChild, needsWrap, wrappers = 0;
    while (firstChild && isElt(firstChild) && (needsWrap = wrapMap[firstChild.nodeName.toLowerCase()])) {
      for (let i = needsWrap.length - 1; i >= 0; i--) {
        let wrapper = doc3.createElement(needsWrap[i]);
        while (wrap2.firstChild)
          wrapper.appendChild(wrap2.firstChild);
        wrap2.appendChild(wrapper);
        wrappers++;
      }
      firstChild = wrap2.firstChild;
    }
    if (firstChild && isElt(firstChild))
      firstChild.setAttribute("data-pm-slice", `${openStart} ${openEnd}${wrappers ? ` -${wrappers}` : ""} ${JSON.stringify(context)}`);
    let text = view.someProp("clipboardTextSerializer", (f) => f(slice2, view)) || slice2.content.textBetween(0, slice2.content.size, "\n\n");
    return { dom: wrap2, text, slice: slice2 };
  }
  function parseFromClipboard(view, text, html, plainText, $context) {
    let inCode = $context.parent.type.spec.code;
    let dom, slice2;
    if (!html && !text)
      return null;
    let asText = !!text && (plainText || inCode || !html);
    if (asText) {
      view.someProp("transformPastedText", (f) => {
        text = f(text, inCode || plainText, view);
      });
      if (inCode) {
        slice2 = new Slice(Fragment.from(view.state.schema.text(text.replace(/\r\n?/g, "\n"))), 0, 0);
        view.someProp("transformPasted", (f) => {
          slice2 = f(slice2, view, true);
        });
        return slice2;
      }
      let parsed = view.someProp("clipboardTextParser", (f) => f(text, $context, plainText, view));
      if (parsed) {
        slice2 = parsed;
      } else {
        let marks2 = $context.marks();
        let { schema: schema2 } = view.state, serializer = DOMSerializer.fromSchema(schema2);
        dom = document.createElement("div");
        text.split(/(?:\r\n?|\n)+/).forEach((block) => {
          let p = dom.appendChild(document.createElement("p"));
          if (block)
            p.appendChild(serializer.serializeNode(schema2.text(block, marks2)));
        });
      }
    } else {
      view.someProp("transformPastedHTML", (f) => {
        html = f(html, view);
      });
      dom = readHTML(html);
      if (webkit)
        restoreReplacedSpaces(dom);
    }
    let contextNode = dom && dom.querySelector("[data-pm-slice]");
    let sliceData = contextNode && /^(\d+) (\d+)(?: -(\d+))? (.*)/.exec(contextNode.getAttribute("data-pm-slice") || "");
    if (sliceData && sliceData[3])
      for (let i = +sliceData[3]; i > 0; i--) {
        let child = dom.firstChild;
        while (child && !isElt(child))
          child = child.nextSibling;
        if (!child)
          break;
        dom = child;
      }
    if (!slice2) {
      let parser = view.someProp("clipboardParser") || view.someProp("domParser") || DOMParser.fromSchema(view.state.schema);
      slice2 = parser.parseSlice(dom, {
        preserveWhitespace: !!(asText || sliceData),
        context: $context,
        ruleFromNode(dom2) {
          if (dom2.nodeName == "BR" && !dom2.nextSibling && dom2.parentNode && !inlineParents.test(dom2.parentNode.nodeName))
            return { ignore: true };
          return null;
        }
      });
    }
    if (sliceData) {
      slice2 = addContext(closeSlice(slice2, +sliceData[1], +sliceData[2]), sliceData[4]);
    } else {
      slice2 = Slice.maxOpen(normalizeSiblings(slice2.content, $context), true);
      if (slice2.openStart || slice2.openEnd) {
        let openStart = 0, openEnd = 0;
        for (let node = slice2.content.firstChild; openStart < slice2.openStart && !node.type.spec.isolating; openStart++, node = node.firstChild) {
        }
        for (let node = slice2.content.lastChild; openEnd < slice2.openEnd && !node.type.spec.isolating; openEnd++, node = node.lastChild) {
        }
        slice2 = closeSlice(slice2, openStart, openEnd);
      }
    }
    view.someProp("transformPasted", (f) => {
      slice2 = f(slice2, view, plainText);
    });
    return slice2;
  }
  var inlineParents = /^(a|abbr|acronym|b|cite|code|del|em|i|ins|kbd|label|output|q|ruby|s|samp|span|strong|sub|sup|time|u|tt|var)$/i;
  function normalizeSiblings(fragment, $context) {
    if (fragment.childCount < 2)
      return fragment;
    for (let d = $context.depth; d >= 0; d--) {
      let parent = $context.node(d);
      let match = parent.contentMatchAt($context.index(d));
      let lastWrap, result = [];
      fragment.forEach((node) => {
        if (!result)
          return;
        let wrap2 = match.findWrapping(node.type), inLast;
        if (!wrap2)
          return result = null;
        if (inLast = result.length && lastWrap.length && addToSibling(wrap2, lastWrap, node, result[result.length - 1], 0)) {
          result[result.length - 1] = inLast;
        } else {
          if (result.length)
            result[result.length - 1] = closeRight(result[result.length - 1], lastWrap.length);
          let wrapped = withWrappers(node, wrap2);
          result.push(wrapped);
          match = match.matchType(wrapped.type);
          lastWrap = wrap2;
        }
      });
      if (result)
        return Fragment.from(result);
    }
    return fragment;
  }
  function withWrappers(node, wrap2, from2 = 0) {
    for (let i = wrap2.length - 1; i >= from2; i--)
      node = wrap2[i].create(null, Fragment.from(node));
    return node;
  }
  function addToSibling(wrap2, lastWrap, node, sibling, depth) {
    if (depth < wrap2.length && depth < lastWrap.length && wrap2[depth] == lastWrap[depth]) {
      let inner = addToSibling(wrap2, lastWrap, node, sibling.lastChild, depth + 1);
      if (inner)
        return sibling.copy(sibling.content.replaceChild(sibling.childCount - 1, inner));
      let match = sibling.contentMatchAt(sibling.childCount);
      if (match.matchType(depth == wrap2.length - 1 ? node.type : wrap2[depth + 1]))
        return sibling.copy(sibling.content.append(Fragment.from(withWrappers(node, wrap2, depth + 1))));
    }
  }
  function closeRight(node, depth) {
    if (depth == 0)
      return node;
    let fragment = node.content.replaceChild(node.childCount - 1, closeRight(node.lastChild, depth - 1));
    let fill = node.contentMatchAt(node.childCount).fillBefore(Fragment.empty, true);
    return node.copy(fragment.append(fill));
  }
  function closeRange(fragment, side, from2, to, depth, openEnd) {
    let node = side < 0 ? fragment.firstChild : fragment.lastChild, inner = node.content;
    if (fragment.childCount > 1)
      openEnd = 0;
    if (depth < to - 1)
      inner = closeRange(inner, side, from2, to, depth + 1, openEnd);
    if (depth >= from2)
      inner = side < 0 ? node.contentMatchAt(0).fillBefore(inner, openEnd <= depth).append(inner) : inner.append(node.contentMatchAt(node.childCount).fillBefore(Fragment.empty, true));
    return fragment.replaceChild(side < 0 ? 0 : fragment.childCount - 1, node.copy(inner));
  }
  function closeSlice(slice2, openStart, openEnd) {
    if (openStart < slice2.openStart)
      slice2 = new Slice(closeRange(slice2.content, -1, openStart, slice2.openStart, 0, slice2.openEnd), openStart, slice2.openEnd);
    if (openEnd < slice2.openEnd)
      slice2 = new Slice(closeRange(slice2.content, 1, openEnd, slice2.openEnd, 0, 0), slice2.openStart, openEnd);
    return slice2;
  }
  var wrapMap = {
    thead: ["table"],
    tbody: ["table"],
    tfoot: ["table"],
    caption: ["table"],
    colgroup: ["table"],
    col: ["table", "colgroup"],
    tr: ["table", "tbody"],
    td: ["table", "tbody", "tr"],
    th: ["table", "tbody", "tr"]
  };
  function detachedDoc() {
    return document.implementation.createHTMLDocument("title");
  }
  var _policy = null;
  function maybeWrapTrusted(html) {
    let trustedTypes = window.trustedTypes;
    if (!trustedTypes)
      return html;
    if (!_policy) {
      if (_policy = trustedTypes.defaultPolicy)
        try {
          return _policy.createHTML(html);
        } catch (_a) {
        }
      _policy = trustedTypes.createPolicy("ProseMirrorClipboard", { createHTML: (s) => s });
    }
    return _policy.createHTML(html);
  }
  function readHTML(html) {
    let metas = /^(\s*<meta [^>]*>)*/.exec(html);
    if (metas)
      html = html.slice(metas[0].length);
    let doc3 = detachedDoc(), elt = doc3.body;
    let firstTag = /<([a-z][^>\s]+)/i.exec(html), wrap2;
    if (wrap2 = firstTag && wrapMap[firstTag[1].toLowerCase()])
      html = wrap2.map((n) => "<" + n + ">").join("") + html + wrap2.map((n) => "</" + n + ">").reverse().join("");
    elt.innerHTML = maybeWrapTrusted(html);
    if (wrap2)
      for (let i = 0; i < wrap2.length; i++)
        elt = elt.querySelector(wrap2[i]) || elt;
    for (let i = 0; i < doc3.styleSheets.length; i++) {
      let style = doc3.styleSheets[i];
      for (let j = 0; j < style.rules.length; j++) {
        let rule = style.rules[j];
        if (rule instanceof CSSStyleRule) {
          let matches2 = elt.querySelectorAll(rule.selectorText);
          for (let k = 0; k < matches2.length; k++)
            matches2[k].style.cssText += rule.style.cssText;
        }
      }
    }
    return elt;
  }
  function restoreReplacedSpaces(dom) {
    let nodes2 = dom.querySelectorAll(chrome ? "span:not([class]):not([style])" : "span.Apple-converted-space");
    for (let i = 0; i < nodes2.length; i++) {
      let node = nodes2[i];
      if (node.childNodes.length == 1 && node.textContent == "\xA0" && node.parentNode)
        node.parentNode.replaceChild(dom.ownerDocument.createTextNode(" "), node);
    }
  }
  function addContext(slice2, context) {
    if (!slice2.size)
      return slice2;
    let schema2 = slice2.content.firstChild.type.schema, array;
    try {
      array = JSON.parse(context);
    } catch (e) {
      return slice2;
    }
    let { content, openStart, openEnd } = slice2;
    for (let i = array.length - 2; i >= 0; i -= 2) {
      let type = schema2.nodes[array[i]];
      if (!type || type.hasRequiredAttrs() || !type.createAndFill(null, content))
        break;
      try {
        content = Fragment.from(type.create(array[i + 1], content));
      } catch (e) {
        break;
      }
      openStart++;
      openEnd++;
    }
    return new Slice(content, openStart, openEnd);
  }
  var StoredDOMSel = class _StoredDOMSel {
    constructor(anchorNode, anchorOffset, focusNode, focusOffset) {
      this.anchorNode = anchorNode;
      this.anchorOffset = anchorOffset;
      this.focusNode = focusNode;
      this.focusOffset = focusOffset;
    }
    static from(range) {
      if (range instanceof _StoredDOMSel)
        return range;
      return new _StoredDOMSel(range.anchorNode, range.anchorOffset, range.focusNode, range.focusOffset);
    }
    eq(sel) {
      return sel.anchorNode == this.anchorNode && sel.anchorOffset == this.anchorOffset && sel.focusNode == this.focusNode && sel.focusOffset == this.focusOffset;
    }
  };
  StoredDOMSel.null = new StoredDOMSel(null, 0, null, 0);
  var DOMSelState = class {
    constructor(view) {
      this.view = view;
      this.range = StoredDOMSel.null;
      this.active = false;
      this.synced = false;
      this.suppress = false;
      this.currentDocument = null;
      this.onSelectionChange = this.onSelectionChange.bind(this);
    }
    ensureListener() {
      let doc3 = this.view.dom.ownerDocument;
      if (doc3 != this.currentDocument) {
        if (this.currentDocument)
          this.currentDocument.removeEventListener("selectionchange", this.onSelectionChange);
        this.currentDocument = doc3;
        doc3.addEventListener("selectionchange", this.onSelectionChange);
      }
    }
    destroy() {
      if (this.currentDocument) {
        this.currentDocument.removeEventListener("selectionchange", this.onSelectionChange);
        this.currentDocument = null;
      }
      this.active = false;
      this.range = StoredDOMSel.null;
    }
    suppressChanges() {
      this.suppress = true;
      setTimeout(() => this.suppress = false, 50);
    }
    onSelectionChange() {
      if (this.suppress && this.view.hasFocus())
        return this.sync();
      if (this.read())
        this.view.domObserver.flush(false);
    }
    // Reads the active range from the DOM, if any.
    readRange() {
      let { view } = this;
      let sel = view.dom.isConnected !== false && view.domSelection();
      if (!sel)
        return StoredDOMSel.null;
      if (safari && view.root.nodeType === 11 && deepActiveElement(view.dom.ownerDocument) == view.dom)
        return StoredDOMSel.from(safariShadowSelectionRange(view, sel) || sel);
      return StoredDOMSel.from(sel);
    }
    read() {
      this.ensureListener();
      let sel = hasFocusAndSelection(this.view);
      if (!sel) {
        this.active = false;
        this.range = StoredDOMSel.null;
        return;
      }
      this.active = true;
      if (this.range.eq(sel))
        return false;
      this.range = sel;
      this.synced = false;
      return true;
    }
    // Sync the DOM selection to the state selection
    sync(force = false) {
      let { view } = this;
      if (!view.docView)
        return;
      this.ensureListener();
      view.domObserver.stopped(() => {
        syncNodeSelection(view, view.state.selection);
        let sel = view.state.selection;
        if (view.input.mouseSelecting || editorOwnsSelection(view)) {
          let { desc, start } = innerViewDesc(view.docView, sel.from, sel.to, 0);
          if (view.cursorWrapper) {
            selectCursorWrapper(view);
          } else if (desc instanceof CustomNodeViewDesc && desc.spec.setSelection) {
            desc.spec.setSelection(sel.anchor - start, sel.head - start, view.root);
          } else {
            selectionToDOM(view, force, desc, start);
          }
          this.synced = this.active = true;
        }
        if (sel.visible == view.dom.classList.contains("ProseMirror-hideselection")) {
          if (sel.visible) {
            view.dom.classList.remove("ProseMirror-hideselection");
          } else {
            view.dom.classList.add("ProseMirror-hideselection");
            removeClassOnSelectionChange(view);
          }
        }
        this.range = this.readRange();
      });
    }
    ignore(sel = this.readRange()) {
      this.range = StoredDOMSel.from(sel);
      this.synced = true;
    }
    // Called when the editor is blurred
    deactivate() {
      this.range = StoredDOMSel.null;
      this.active = this.synced = false;
    }
  };
  function safariShadowSelectionRange(view, selection) {
    if (selection.getComposedRanges) {
      let range = selection.getComposedRanges({ shadowRoots: [view.root] })[0];
      if (range)
        return rangeToSelectionRange(view, range);
    }
    let found2;
    function read(event) {
      event.preventDefault();
      event.stopImmediatePropagation();
      found2 = event.getTargetRanges()[0];
    }
    view.dom.addEventListener("beforeinput", read, true);
    document.execCommand("indent");
    view.dom.removeEventListener("beforeinput", read, true);
    return found2 ? rangeToSelectionRange(view, found2) : null;
  }
  function rangeToSelectionRange(view, range) {
    let anchorNode = range.startContainer, anchorOffset = range.startOffset;
    let focusNode = range.endContainer, focusOffset = range.endOffset;
    let currentAnchor = view.domAtPos(view.state.selection.anchor);
    if (isEquivalentPosition(currentAnchor.node, currentAnchor.offset, focusNode, focusOffset))
      [anchorNode, anchorOffset, focusNode, focusOffset] = [focusNode, focusOffset, anchorNode, anchorOffset];
    return new StoredDOMSel(anchorNode, anchorOffset, focusNode, focusOffset);
  }
  function selectionFromDOM(view, domSel, origin = null) {
    let doc3 = view.state.doc;
    if (!domSel.focusNode)
      return null;
    let nearestDesc = view.docView.nearestDesc(domSel.focusNode), inWidget = nearestDesc && nearestDesc.size == 0;
    let head = view.docView.posFromDOM(domSel.focusNode, domSel.focusOffset, 1);
    if (head < 0)
      return null;
    let $head = doc3.resolve(head), anchor, selection;
    if (selectionCollapsed(domSel)) {
      anchor = head;
      while (nearestDesc && !nearestDesc.node)
        nearestDesc = nearestDesc.parent;
      if (nearestDesc && nearestDesc.node.isAtom && NodeSelection.isSelectable(nearestDesc.node) && nearestDesc.parent && !(nearestDesc.node.isInline && isOnEdge(domSel.focusNode, domSel.focusOffset, nearestDesc.dom))) {
        let pos = nearestDesc.posBefore;
        selection = new NodeSelection(head == pos ? $head : doc3.resolve(pos));
      } else if (gecko && origin == "key" && head > view.state.selection.to && isElt(domSel.focusNode) && domSel.focusOffset == domSel.focusNode.childNodes.length && nearestDesc && nearestDesc.posAtStart > view.state.selection.to) {
        for (let scan = domSel.focusNode; ; scan = scan.parentNode) {
          if (getComputedStyle(scan).overflow != "visible") {
            selection = Selection.findFrom(doc3.resolve(nearestDesc.posAtStart), 1);
            break;
          }
          if (scan == nearestDesc.dom || scan.nextSibling || !scan.parentNode || !isElt(scan.parentNode))
            break;
        }
      }
    } else {
      if (domSel instanceof view.dom.ownerDocument.defaultView.Selection && domSel.rangeCount > 1) {
        let min = head, max = head;
        for (let i = 0; i < domSel.rangeCount; i++) {
          let range = domSel.getRangeAt(i);
          min = Math.min(min, view.docView.posFromDOM(range.startContainer, range.startOffset, 1));
          max = Math.max(max, view.docView.posFromDOM(range.endContainer, range.endOffset, -1));
        }
        if (min < 0)
          return null;
        [anchor, head] = max == view.state.selection.anchor ? [max, min] : [min, max];
        $head = doc3.resolve(head);
      } else {
        anchor = view.docView.posFromDOM(domSel.anchorNode, domSel.anchorOffset, 1);
      }
      if (anchor < 0)
        return null;
    }
    let $anchor = doc3.resolve(anchor);
    if (!selection) {
      let bias = origin == "pointer" || view.state.selection.head < $head.pos && !inWidget ? 1 : -1;
      selection = selectionBetween(view, $anchor, $head, bias);
    }
    return selection;
  }
  function editorOwnsSelection(view) {
    return view.editable ? view.hasFocus() : hasSelection(view, view.domSel.readRange()) && (!document.activeElement || document.activeElement.contains(view.dom));
  }
  function selectionToDOM(view, force, desc, start) {
    let sel = view.state.selection;
    let { anchor, head } = sel, resetEditableFrom, resetEditableTo;
    if (brokenSelectBetweenUneditable && !(sel instanceof TextSelection)) {
      if (!sel.$from.parent.inlineContent)
        resetEditableFrom = temporarilyEditableNear(view, sel.from);
      if (!sel.empty && !sel.$from.parent.inlineContent)
        resetEditableTo = temporarilyEditableNear(view, sel.to);
    }
    let anchorDOM = desc.domFromPos(anchor - start, anchor > start ? -1 : 1);
    let headDOM = head == anchor ? anchorDOM : desc.domFromPos(head - start, head > start ? -1 : 1);
    setSelection(anchor, head, anchorDOM, headDOM, view, force);
    if (brokenSelectBetweenUneditable) {
      if (resetEditableFrom)
        resetEditable(resetEditableFrom);
      if (resetEditableTo)
        resetEditable(resetEditableTo);
    }
  }
  function innerViewDesc(desc, from2, to, start = 0) {
    for (let i = 0, off = start; i < desc.children.length; i++) {
      let child = desc.children[i], end = off + child.size;
      if (from2 > off && to < end)
        return innerViewDesc(child, from2, to, off + child.border);
      off = end;
    }
    return { desc, start };
  }
  function setSelection(anchor, head, anchorDOM, headDOM, view, force) {
    let brKludge = false;
    if ((gecko || safari) && anchor == head) {
      let { node, offset } = anchorDOM;
      if (isText(node)) {
        brKludge = !!(offset && node.nodeValue[offset - 1] == "\n");
        if (brKludge && offset == node.nodeValue.length) {
          for (let scan = node, after; scan; scan = scan.parentNode) {
            if (after = scan.nextSibling) {
              if (after.nodeName == "BR")
                anchorDOM = headDOM = { node: after.parentNode, offset: domIndex(after) + 1 };
              break;
            }
            let desc = scan.pmViewDesc;
            if (desc && desc.node && desc.node.isBlock)
              break;
          }
        }
      } else {
        let prev = node.childNodes[offset - 1];
        brKludge = prev && (prev.nodeName == "BR" || prev.contentEditable == "false");
      }
    }
    let selRange = view.domSel.readRange();
    if (gecko && selRange.focusNode && selRange.focusNode != headDOM.node && isElt(selRange.focusNode)) {
      let after = selRange.focusNode.childNodes[selRange.focusOffset];
      if (after && after.contentEditable == "false")
        force = true;
    }
    if (!(force || brKludge && safari) && isEquivalentPosition(anchorDOM.node, anchorDOM.offset, selRange.anchorNode, selRange.anchorOffset) && isEquivalentPosition(headDOM.node, headDOM.offset, selRange.focusNode, selRange.focusOffset))
      return;
    let domSel = view.domSelection(), mouse = view.input.mouseSelecting;
    if (mouse && mouse.affinity && anchor == head && mouse.pos == anchor) {
      let { affinity } = mouse;
      let { node, offset } = headDOM, targetNode, targetOffset = 0;
      if (isText(node) && (affinity > 0 ? offset < nodeSize(node) : offset > 0)) {
        targetNode = node;
        targetOffset = offset + affinity;
      } else {
        targetNode = (affinity > 0 ? textNodeAfter : textNodeBefore)(node, offset);
        if (targetNode)
          targetOffset = affinity > 0 ? 1 : targetNode.nodeValue.length - 1;
      }
      if (targetNode) {
        domSel.collapse(targetNode, targetOffset);
        domSel.modify("move", affinity > 0 ? "backward" : "forward", "lineboundary");
        let { focusNode, focusOffset } = domSel;
        if (safari && view.root.nodeType == 11) {
          let ranges = domSel.getComposedRanges({ shadowRoots: [view.root] });
          if (ranges.length) {
            focusNode = ranges[0].startContainer;
            focusOffset = ranges[0].startOffset;
          }
        }
        if (isEquivalentPosition(node, offset, focusNode, focusOffset))
          return;
      }
    }
    writeSelection(domSel, {
      focusNode: headDOM.node,
      focusOffset: headDOM.offset,
      anchorNode: anchorDOM.node,
      anchorOffset: anchorDOM.offset
    });
  }
  var brokenSelectBetweenUneditable = safari || chrome && chrome_version < 63;
  function temporarilyEditableNear(view, pos) {
    let { node, offset } = view.docView.domFromPos(pos, 0);
    let after = offset < node.childNodes.length ? node.childNodes[offset] : null;
    let before = offset ? node.childNodes[offset - 1] : null;
    if (safari && after && after.contentEditable == "false")
      return setEditable(after);
    if ((!after || after.contentEditable == "false") && (!before || before.contentEditable == "false")) {
      if (after)
        return setEditable(after);
      else if (before)
        return setEditable(before);
    }
  }
  function setEditable(element) {
    element.contentEditable = "true";
    if (safari && element.draggable) {
      element.draggable = false;
      element.wasDraggable = true;
    }
    return element;
  }
  function resetEditable(element) {
    element.contentEditable = "false";
    if (element.wasDraggable) {
      element.draggable = true;
      element.wasDraggable = null;
    }
  }
  function removeClassOnSelectionChange(view) {
    let doc3 = view.dom.ownerDocument;
    doc3.removeEventListener("selectionchange", view.input.hideSelectionGuard);
    let domSel = view.domSel.readRange();
    let node = domSel.anchorNode, offset = domSel.anchorOffset;
    doc3.addEventListener("selectionchange", view.input.hideSelectionGuard = () => {
      if (domSel.anchorNode != node || domSel.anchorOffset != offset) {
        doc3.removeEventListener("selectionchange", view.input.hideSelectionGuard);
        setTimeout(() => {
          if (!editorOwnsSelection(view) || view.state.selection.visible)
            view.dom.classList.remove("ProseMirror-hideselection");
        }, 20);
      }
    });
  }
  function selectCursorWrapper(view) {
    let domSel = view.domSelection();
    if (!domSel)
      return;
    let node = view.cursorWrapper.dom, img = node.nodeName == "IMG";
    if (img)
      domSel.collapse(node.parentNode, domIndex(node) + 1);
    else
      domSel.collapse(node, 0);
  }
  function syncNodeSelection(view, sel) {
    if (sel instanceof NodeSelection) {
      let desc = view.docView.descAt(sel.from);
      if (desc != view.lastSelectedViewDesc) {
        clearNodeSelection(view);
        if (desc)
          desc.selectNode();
        view.lastSelectedViewDesc = desc;
      }
    } else {
      clearNodeSelection(view);
    }
  }
  function clearNodeSelection(view) {
    if (view.lastSelectedViewDesc) {
      if (view.lastSelectedViewDesc.parent)
        view.lastSelectedViewDesc.deselectNode();
      view.lastSelectedViewDesc = void 0;
    }
  }
  function selectionBetween(view, $anchor, $head, bias) {
    let sel = view.someProp("createSelectionBetween", (f) => f(view, $anchor, $head)) || TextSelection.between($anchor, $head, bias);
    view.someProp("adjustSelectionFromDOM", (f) => {
      sel = f(view, sel);
    });
    return sel;
  }
  function hasFocusAndSelection(view) {
    if (view.editable && !view.hasFocus())
      return null;
    let sel = view.domSel.readRange();
    return sel && hasSelection(view, sel) ? sel : null;
  }
  function hasSelection(view, sel) {
    if (!sel.anchorNode)
      return false;
    try {
      return contains(view.dom, sel.anchorNode) && (view.editable || contains(view.dom, sel.focusNode));
    } catch (_) {
      return false;
    }
  }
  var handlers = {};
  var editHandlers = {};
  var passiveHandlers = { touchstart: true, touchmove: true };
  var InputState = class {
    constructor() {
      this.shiftKey = false;
      this.mouseDown = null;
      this.lastKeyCode = null;
      this.lastKeyCodeTime = 0;
      this.lastKeyDispatched = false;
      this.lastClick = { time: 0, x: 0, y: 0, type: "", button: 0 };
      this.lastSelectionOrigin = null;
      this.lastSelectionTime = 0;
      this.lastIOSEnter = 0;
      this.lastIOSEnterFallbackTimeout = -1;
      this.lastFocus = 0;
      this.lastTouch = 0;
      this.lastChromeDelete = 0;
      this.composing = false;
      this.compositionNode = null;
      this.composingTimeout = -1;
      this.compositionNodes = [];
      this.compositionEndedAt = -2e8;
      this.compositionID = 1;
      this.mouseSelecting = null;
      this.badSafariComposition = false;
      this.compositionPendingChanges = 0;
      this.domChangeCount = 0;
      this.eventHandlers = /* @__PURE__ */ Object.create(null);
      this.hideSelectionGuard = null;
    }
  };
  function initInput(view) {
    for (let event in handlers) {
      let handler = handlers[event];
      view.dom.addEventListener(event, view.input.eventHandlers[event] = (event2) => {
        if (!eventBelongsToView(view, event2))
          return;
        if (view.input.composing && (event2.type == "keydown" || event2.type == "beforeinput") && event2.isComposing === false)
          leaveComposition(view, true);
        if (!runCustomHandler(view, event2) && (view.editable || !(event2.type in editHandlers)))
          handler(view, event2);
      }, passiveHandlers[event] ? { passive: true } : void 0);
    }
    if (safari)
      view.dom.addEventListener("input", () => null);
    ensureListeners(view);
  }
  function setSelectionOrigin(view, origin) {
    view.input.lastSelectionOrigin = origin;
    view.input.lastSelectionTime = Date.now();
  }
  function destroyInput(view) {
    if (view.input.mouseDown)
      view.input.mouseDown.done();
    view.domObserver.stop();
    for (let type in view.input.eventHandlers)
      view.dom.removeEventListener(type, view.input.eventHandlers[type]);
    clearTimeout(view.input.composingTimeout);
    clearTimeout(view.input.lastIOSEnterFallbackTimeout);
  }
  function ensureListeners(view) {
    view.someProp("handleDOMEvents", (currentHandlers) => {
      for (let type in currentHandlers)
        if (!view.input.eventHandlers[type])
          view.dom.addEventListener(type, view.input.eventHandlers[type] = (event) => runCustomHandler(view, event));
    });
  }
  function runCustomHandler(view, event) {
    return view.someProp("handleDOMEvents", (handlers2) => {
      let handler = handlers2[event.type];
      return handler ? handler(view, event) || event.defaultPrevented : false;
    });
  }
  function eventBelongsToView(view, event) {
    if (!event.bubbles)
      return true;
    if (event.defaultPrevented)
      return false;
    for (let node = event.target; node != view.dom; node = node.parentNode)
      if (!node || node.nodeType == 11 || node.pmViewDesc && node.pmViewDesc.stopEvent(event))
        return false;
    return true;
  }
  function dispatchEvent(view, event) {
    if (!runCustomHandler(view, event) && handlers[event.type] && (view.editable || !(event.type in editHandlers)))
      handlers[event.type](view, event);
  }
  function dispatchKey(view, event) {
    let { input } = view;
    if (input.lastKeyDispatched || view.composing)
      return false;
    input.lastKeyDispatched = true;
    if (typeof event == "string")
      event = keyEvent(event == "Backspace" ? 8 : 13, event);
    return view.someProp("handleKeyDown", (f) => f(view, event));
  }
  editHandlers.keydown = (view, _event) => {
    let event = _event;
    view.input.shiftKey = event.keyCode == 16 || event.shiftKey;
    view.input.lastKeyCode = event.keyCode;
    view.input.lastKeyCodeTime = Date.now();
    view.input.lastKeyDispatched = false;
    if (android && chrome && event.keyCode == 13)
      return;
    if (ios && event.keyCode == 13 && !event.ctrlKey && !event.altKey && !event.metaKey) {
      let now = Date.now();
      view.input.lastIOSEnter = now;
      view.input.lastIOSEnterFallbackTimeout = setTimeout(() => {
        if (view.input.lastIOSEnter == now) {
          dispatchKey(view, "Enter");
          view.input.lastIOSEnter = 0;
        }
      }, 200);
      return;
    }
    if (event.keyCode != 229)
      view.domObserver.forceFlush(true);
    if (dispatchKey(view, event) || captureKeyDown(view, event))
      event.preventDefault();
    else
      setSelectionOrigin(view, "key");
  };
  editHandlers.keyup = (view, event) => {
    if (event.keyCode == 16)
      view.input.shiftKey = false;
  };
  editHandlers.keypress = (view, _event) => {
    let event = _event;
    if (inOrNearComposition(view) || !event.charCode || event.ctrlKey && !event.altKey || mac && event.metaKey)
      return;
    if (view.someProp("handleKeyPress", (f) => f(view, event))) {
      event.preventDefault();
      return;
    }
    let sel = view.state.selection;
    if (!(sel instanceof TextSelection) || !sel.$from.sameParent(sel.$to)) {
      let text = String.fromCharCode(event.charCode);
      let deflt = () => view.state.tr.insertText(text).scrollIntoView();
      if (!/[\r\n]/.test(text) && !view.someProp("handleTextInput", (f) => f(view, sel.$from.pos, sel.$to.pos, text, deflt)))
        view.dispatch(deflt());
      event.preventDefault();
    }
  };
  function eventCoords(event) {
    return { left: event.clientX, top: event.clientY };
  }
  function isNear(event, click) {
    let dx = click.x - event.clientX, dy = click.y - event.clientY;
    return dx * dx + dy * dy < 100;
  }
  function runHandlerOnContext(view, propName, pos, inside, event) {
    if (inside == -1)
      return false;
    let $pos = view.state.doc.resolve(inside);
    for (let i = $pos.depth + 1; i > 0; i--) {
      if (view.someProp(propName, (f) => i > $pos.depth ? f(view, pos, $pos.nodeAfter, $pos.before(i), event, true) : f(view, pos, $pos.node(i), $pos.before(i), event, false)))
        return true;
    }
    return false;
  }
  function updateSelection(view, selection, origin) {
    if (!view.focused)
      view.focus();
    if (view.state.selection.eq(selection))
      return;
    let tr = view.state.tr.setSelection(selection);
    tr.setMeta("pointer", true);
    view.dispatch(tr);
  }
  function selectClickedLeaf(view, inside) {
    if (inside == -1)
      return false;
    let $pos = view.state.doc.resolve(inside), node = $pos.nodeAfter;
    if (node && node.isAtom && NodeSelection.isSelectable(node)) {
      updateSelection(view, new NodeSelection($pos));
      return true;
    }
    return false;
  }
  function selectClickedNode(view, inside) {
    if (inside == -1)
      return false;
    let sel = view.state.selection, selectedNode, selectAt;
    if (sel instanceof NodeSelection)
      selectedNode = sel.node;
    let $pos = view.state.doc.resolve(inside);
    for (let i = $pos.depth + 1; i > 0; i--) {
      let node = i > $pos.depth ? $pos.nodeAfter : $pos.node(i);
      if (NodeSelection.isSelectable(node)) {
        if (selectedNode && sel.$from.depth > 0 && i >= sel.$from.depth && $pos.before(sel.$from.depth + 1) == sel.$from.pos)
          selectAt = $pos.before(sel.$from.depth);
        else
          selectAt = $pos.before(i);
        break;
      }
    }
    if (selectAt != null) {
      updateSelection(view, NodeSelection.create(view.state.doc, selectAt));
      return true;
    } else {
      return false;
    }
  }
  function handleSingleClick(view, pos, inside, event, selectNode) {
    return runHandlerOnContext(view, "handleClickOn", pos, inside, event) || view.someProp("handleClick", (f) => f(view, pos, event)) || (selectNode ? selectClickedNode(view, inside) : selectClickedLeaf(view, inside));
  }
  function handleDoubleClick(view, pos, inside, event) {
    return runHandlerOnContext(view, "handleDoubleClickOn", pos, inside, event) || view.someProp("handleDoubleClick", (f) => f(view, pos, event));
  }
  function handleTripleClick(view, pos, inside, event) {
    return runHandlerOnContext(view, "handleTripleClickOn", pos, inside, event) || view.someProp("handleTripleClick", (f) => f(view, pos, event));
  }
  function selectionForTripleClick(doc3, inside, selectNodes) {
    if (inside == -1)
      return doc3.inlineContent ? TextSelection.create(doc3, 0, doc3.content.size) : null;
    let $pos = doc3.resolve(inside);
    for (let i = $pos.depth + 1; i > 0; i--) {
      let node = i > $pos.depth ? $pos.nodeAfter : $pos.node(i);
      let nodePos = $pos.before(i);
      if (node.inlineContent)
        return TextSelection.create(doc3, nodePos + 1, nodePos + 1 + node.content.size);
      else if (selectNodes && NodeSelection.isSelectable(node))
        return NodeSelection.create(doc3, nodePos);
    }
    return null;
  }
  var wordRE = /[\w_\u00a1-\uffff]+/g;
  try {
    wordRE = new RegExp("[\\p{L}\\p{N}_]+", "gu");
  } catch (_a) {
  }
  function getWordAt(doc3, pos) {
    let $pos = doc3.resolve(pos), parent = $pos.node();
    let context = "", from2 = pos, to = pos;
    for (let i = $pos.indexAfter(), sawNonWS = false; i > 0; i--) {
      let prev = parent.child(i - 1);
      if (!prev.text)
        break;
      let end = from2 == pos ? pos - $pos.posAtIndex(i - 1) : prev.text.length, start = end;
      for (; start > 0; start--) {
        if (/\S/.test(prev.text[start - 1]))
          sawNonWS = true;
        else if (sawNonWS)
          break;
      }
      context = prev.text.slice(start, end) + context;
      from2 -= end - start;
      if (start || from2 < pos - 50)
        break;
    }
    for (let i = $pos.index(), sawNonWS = false; i < parent.childCount; i++) {
      let next = parent.child(i);
      if (!next.text)
        break;
      let start = to == pos ? pos - $pos.posAtIndex(i) : 0, end = start;
      for (; end < next.text.length; end++) {
        if (/\S/.test(next.text[end]))
          sawNonWS = true;
        else if (sawNonWS)
          break;
      }
      context += next.text.slice(start, end);
      to += end - start;
      if (end < next.text.length || to > pos + 50)
        break;
    }
    let lastBefore = from2, firstAfter = to;
    if (Intl.Segmenter) {
      for (let segment of new Intl.Segmenter(void 0, { granularity: "word" }).segment(context)) {
        if (segment.isWordLike) {
          let start = segment.index + from2, end = start + segment.segment.length;
          if (end < pos)
            lastBefore = end;
          else if (start > pos) {
            firstAfter = start;
            break;
          } else
            return TextSelection.create(doc3, start, end);
        }
      }
    } else {
      wordRE.lastIndex = 0;
      for (let m; m = wordRE.exec(context); ) {
        let start = m.index + from2, end = start + m[0].length;
        if (end < pos)
          lastBefore = end;
        else if (start > pos) {
          firstAfter = start;
          break;
        } else
          return TextSelection.create(doc3, start, end);
      }
    }
    let before = context.slice(lastBefore - from2, pos - from2), after = context.slice(pos - from2, firstAfter - from2);
    let nonSpaceBefore = /\S*$/.exec(before)[0].length, nonSpaceAfter = /^\S*/.exec(after)[0].length;
    if (nonSpaceBefore || nonSpaceAfter)
      return TextSelection.create(doc3, pos - nonSpaceBefore, pos + nonSpaceAfter);
    let spaceBefore = /\s*$/.exec(before)[0].length, spaceAfter = /^\s*/.exec(after)[0].length;
    return TextSelection.create(doc3, pos - spaceBefore, pos + spaceAfter);
  }
  var selectNodeModifier = mac ? "metaKey" : "ctrlKey";
  handlers.mousedown = (view, _event) => {
    let event = _event, now = Date.now();
    view.input.shiftKey = event.shiftKey;
    if (view.input.lastTouch > now - 500)
      return false;
    endComposition(view);
    let type = "singleClick";
    if (now - view.input.lastClick.time < 500 && isNear(event, view.input.lastClick) && !event[selectNodeModifier] && view.input.lastClick.button == event.button) {
      if (view.input.lastClick.type == "singleClick")
        type = "doubleClick";
      else if (view.input.lastClick.type == "doubleClick")
        type = "tripleClick";
    }
    view.input.lastClick = { time: now, x: event.clientX, y: event.clientY, type, button: event.button };
    if (view.input.mouseDown)
      view.input.mouseDown.done();
    let pos = view.posAtCoords(eventCoords(event));
    if (!pos)
      return;
    if (event.button == 0) {
      if (!view.hasFocus()) {
        focusPreventScroll(view.dom);
        let active = view.root.activeElement;
        if (active && !active.contains(view.dom))
          active.blur();
      }
      let mouseDown = view.input.mouseDown = new MouseDown(view, pos, event, type);
      if (!mouseDown.mightDrag)
        event.preventDefault();
    } else {
      setSelectionOrigin(view, "pointer");
    }
  };
  var MouseDown = class {
    constructor(view, startPos, event, type) {
      var _a;
      this.view = view;
      this.startPos = startPos;
      this.event = event;
      this.type = type;
      this.didMove = false;
      this.lastPos = -1;
      this.anchorRange = null;
      this.startDoc = view.state.doc;
      this.selectNode = !!event[selectNodeModifier];
      this.extend = event.shiftKey;
      this.anchorDoc = this.startDoc;
      let startBase = docBase(view);
      if (this.extend) {
        let sel = view.state.selection;
        this.anchorRange = sel instanceof NodeSelection ? { from: sel.from, to: sel.to } : { from: sel.anchor, to: sel.anchor };
        let rect = sel instanceof NodeSelection ? view.nodeDOM(sel.from).getBoundingClientRect() : view.coordsAtPos(sel.anchor);
        this.anchorOffset = {
          x: (rect.left + rect.right) / 2 - startBase.x,
          y: (rect.top + rect.bottom) / 2 - startBase.y
        };
      } else {
        this.anchorOffset = { x: event.clientX - startBase.x, y: event.clientY - startBase.y };
      }
      if (type == "singleClick") {
        let { selection } = view.state;
        let targetNode, targetPos, targetSelected = false;
        if (selection instanceof NodeSelection && selection.from <= startPos.pos && selection.to >= startPos.pos) {
          targetPos = selection.from;
          targetNode = selection.node;
          targetSelected = true;
        } else if (startPos.inside > -1) {
          targetNode = view.state.doc.nodeAt(startPos.inside);
          targetPos = startPos.inside;
        } else {
          let $pos = view.state.doc.resolve(startPos.pos);
          targetNode = $pos.parent;
          targetPos = $pos.depth ? $pos.before() : -1;
        }
        if (targetSelected || targetPos > -1 && targetNode.type.spec.draggable && targetNode.type.spec.selectable !== false) {
          let elt = (_a = view.docView.descAt(targetPos)) === null || _a === void 0 ? void 0 : _a.nodeDOM;
          this.mightDrag = {
            node: targetNode,
            elt,
            pos: targetPos,
            addAttr: false
          };
          if (elt && !elt.draggable) {
            this.mightDrag.addAttr = true;
            view.domObserver.stopped(() => elt.draggable = true);
          }
        } else {
          this.mightDrag = isInSelection(view, event);
        }
      } else {
        this.mightDrag = false;
      }
      view.root.addEventListener("mouseup", this.up = this.up.bind(this));
      view.root.addEventListener("mousemove", this.move = this.move.bind(this));
      if (!this.mightDrag)
        this.select(this.startPos, true);
    }
    done() {
      this.view.root.removeEventListener("mouseup", this.up);
      this.view.root.removeEventListener("mousemove", this.move);
      if (this.view.input.mouseDown == this)
        this.view.input.mouseDown = null;
      if (typeof this.mightDrag == "object" && this.mightDrag.addAttr) {
        this.view.domObserver.stopped(() => this.mightDrag.elt.removeAttribute("draggable"));
      }
    }
    maybeRunHandler(pos, event) {
      let handler = this.type == "singleClick" ? handleSingleClick : this.type == "doubleClick" ? handleDoubleClick : handleTripleClick;
      return handler(this.view, pos.pos, pos.inside, event, this.selectNode);
    }
    up(event) {
      this.done();
      if (!this.view.dom.contains(event.target))
        return;
      let pos = this.startPos;
      if (this.view.state.doc != this.startDoc)
        pos = this.view.posAtCoords(eventCoords(event));
      if (!pos)
        return;
      if (!this.didMove) {
        this.maybeRunHandler(pos, event) || this.select(pos, true);
      }
      event.preventDefault();
    }
    move(event) {
      if (event.buttons == 0) {
        this.done();
        return;
      }
      if (!this.didMove && (Math.abs(this.event.x - event.clientX) > 8 || Math.abs(this.event.y - event.clientY) > 8)) {
        this.didMove = true;
        this.mightDrag = false;
      }
      if (!this.mightDrag) {
        let pos = this.view.posAtCoords(eventCoords(event));
        if (pos)
          this.select(pos, false);
      }
      event.preventDefault();
    }
    select(pos, first) {
      if (pos.pos == this.lastPos)
        return;
      this.lastPos = pos.pos;
      let { view } = this, { doc: doc3 } = view.state;
      let selection = this.type == "singleClick" ? clickedRange(view, doc3, pos) : this.type == "doubleClick" ? getWordAt(doc3, pos.pos) : selectionForTripleClick(doc3, pos.inside, first);
      if (!selection)
        return;
      if (first && !this.extend) {
        this.anchorRange = selection;
      } else if (!first || this.extend) {
        if (!doc3.eq(this.anchorDoc))
          this.restoreAnchor();
        if (this.anchorRange && this.anchorRange.from < selection.from)
          selection = selectionBetween(view, doc3.resolve(this.anchorRange.from), doc3.resolve(selection.to));
        else if (this.anchorRange && this.anchorRange.to > selection.to)
          selection = selectionBetween(view, doc3.resolve(this.anchorRange.to), doc3.resolve(selection.from));
      }
      if (!selection.eq(view.state.selection)) {
        view.input.mouseSelecting = pos;
        view.dispatch(view.state.tr.setSelection(selection).setMeta("pointer", true).scrollIntoView());
        view.input.mouseSelecting = null;
      }
    }
    restoreAnchor() {
      let base2 = docBase(this.view);
      let pos = this.view.posAtCoords({ left: this.anchorOffset.x + base2.x, top: this.anchorOffset.y + base2.y });
      if (!pos) {
        this.anchorRange = null;
      } else {
        let { doc: doc3 } = this.view.state;
        this.anchorRange = this.type == "singleClick" ? clickedRange(this.view, doc3, pos) : this.type == "doubleClick" ? getWordAt(doc3, pos.pos) : selectionForTripleClick(doc3, pos.inside, false);
        this.anchorDoc = this.view.state.doc;
      }
    }
  };
  function docBase(view) {
    let rect = view.dom.getBoundingClientRect();
    return { x: rect.left - view.dom.scrollLeft, y: rect.top - view.dom.scrollTop };
  }
  function clickedRange(view, doc3, pos) {
    if (pos.inside > -1) {
      let target = doc3.nodeAt(pos.inside);
      if (target.isAtom && NodeSelection.isSelectable(target))
        return NodeSelection.create(doc3, pos.inside);
    }
    let $pos = doc3.resolve(pos.pos);
    return selectionBetween(view, $pos, $pos);
  }
  function isInSelection(view, event) {
    let { selection } = view.state;
    if (selection.empty)
      return false;
    let sel = view.domSelection();
    if (!sel || sel.rangeCount == 0)
      return true;
    let rects = sel.getRangeAt(0).getClientRects();
    for (let i = 0; i < rects.length; i++) {
      let rect = rects[i];
      if (rect.left <= event.clientX && rect.right >= event.clientX && rect.top <= event.clientY && rect.bottom >= event.clientY)
        return true;
    }
    return false;
  }
  handlers.touchstart = (view) => {
    view.input.lastTouch = Date.now();
    endComposition(view);
    setSelectionOrigin(view, "pointer");
  };
  handlers.touchmove = (view) => {
    view.input.lastTouch = Date.now();
    setSelectionOrigin(view, "pointer");
  };
  handlers.contextmenu = (view) => endComposition(view);
  function inOrNearComposition(view, event) {
    if (view.composing)
      return true;
    if (safari && Math.abs(Date.now() - view.input.compositionEndedAt) < 500) {
      view.input.compositionEndedAt = -2e8;
      return true;
    }
    return false;
  }
  var timeoutComposition = android ? 5e3 : -1;
  editHandlers.compositionstart = editHandlers.compositionupdate = (view) => {
    if (!view.composing) {
      view.domObserver.flush();
      let { state } = view, $pos = state.selection.$to;
      if (state.selection instanceof TextSelection && state.selection.empty && (state.storedMarks || !$pos.textOffset && $pos.parentOffset && $pos.nodeBefore.marks.some((m) => m.type.spec.inclusive === false) || chrome && windows && selectionBeforeUneditable(view))) {
        view.markCursor = view.state.storedMarks || $pos.marks();
        endComposition(view, true);
        view.markCursor = null;
      } else {
        endComposition(view, !state.selection.empty);
        if (gecko && view.domSel.active && state.selection.empty && $pos.parentOffset && !$pos.textOffset && $pos.nodeBefore.marks.length) {
          for (let { focusNode: node, focusOffset: offset } = view.domSel.range; node && isElt(node) && offset != 0; ) {
            let before = offset < 0 ? node.lastChild : node.childNodes[offset - 1];
            if (!before)
              break;
            if (isText(before)) {
              let sel = view.domSelection();
              if (sel)
                sel.collapse(before, before.nodeValue.length);
              break;
            } else {
              node = before;
              offset = -1;
            }
          }
        }
      }
      view.input.composing = true;
    }
    scheduleComposeEnd(view, timeoutComposition);
  };
  function selectionBeforeUneditable(view) {
    let { focusNode, focusOffset } = view.domSel.range;
    if (!focusNode || !isElt(focusNode) || focusOffset >= focusNode.childNodes.length)
      return false;
    let next = focusNode.childNodes[focusOffset];
    return isElt(next) && next.contentEditable == "false";
  }
  editHandlers.compositionend = (view, event) => {
    if (view.composing)
      leaveComposition(view);
  };
  function leaveComposition(view, sync = false) {
    view.input.composing = false;
    view.input.compositionEndedAt = Date.now();
    view.input.compositionPendingChanges = view.domObserver.pendingRecords().length ? view.input.compositionID : 0;
    view.input.compositionNode = null;
    if (view.input.badSafariComposition)
      view.domObserver.forceFlush();
    else if (view.input.compositionPendingChanges)
      Promise.resolve().then(() => view.domObserver.flush());
    view.input.compositionID++;
    if (sync)
      endComposition(view);
    else
      scheduleComposeEnd(view, 20);
  }
  function scheduleComposeEnd(view, delay) {
    clearTimeout(view.input.composingTimeout);
    if (delay > -1)
      view.input.composingTimeout = setTimeout(() => endComposition(view), delay);
  }
  function clearComposition(view) {
    if (view.composing) {
      view.input.composing = false;
      view.input.compositionEndedAt = Date.now();
    }
    for (let node; node = view.input.compositionNodes.pop(); )
      node.markParentDamage();
  }
  function findCompositionNode(view) {
    let sel = view.domSel.range;
    if (!view.domSel.active || !sel.focusNode)
      return null;
    let textBefore = textNodeBefore(sel.focusNode, sel.focusOffset);
    let textAfter = textNodeAfter(sel.focusNode, sel.focusOffset);
    if (textBefore && textAfter && textBefore != textAfter) {
      let descAfter = textAfter.pmViewDesc, lastChanged = view.domObserver.lastChangedTextNode;
      if (textBefore == lastChanged || textAfter == lastChanged)
        return lastChanged;
      if (!descAfter || !descAfter.isText(textAfter.nodeValue)) {
        return textAfter;
      } else if (view.input.compositionNode == textAfter) {
        let descBefore = textBefore.pmViewDesc;
        if (!(!descBefore || !descBefore.isText(textBefore.nodeValue)))
          return textAfter;
      }
    }
    return textBefore || textAfter;
  }
  function endComposition(view, restarting = false) {
    if (android && view.domObserver.flushingSoon >= 0)
      return;
    view.domObserver.forceFlush();
    clearComposition(view);
    if (restarting || view.docView && view.docView.damage) {
      let sel = selectionFromDOM(view, view.domSel.readRange()), cur = view.state.selection;
      if (sel && !sel.eq(cur))
        view.dispatch(view.state.tr.setSelection(sel));
      else if ((view.markCursor || restarting) && !cur.$from.node(cur.$from.sharedDepth(cur.to)).inlineContent)
        view.dispatch(view.state.tr.deleteSelection());
      else
        view.updateState(view.state);
    }
  }
  function captureCopy(view, dom) {
    if (!view.dom.parentNode)
      return;
    let wrap2 = view.dom.parentNode.appendChild(document.createElement("div"));
    wrap2.appendChild(dom);
    wrap2.style.cssText = "position: fixed; left: -10000px; top: 10px";
    let sel = getSelection(), range = document.createRange();
    range.selectNodeContents(dom);
    view.dom.blur();
    sel.removeAllRanges();
    sel.addRange(range);
    setTimeout(() => {
      if (wrap2.parentNode)
        wrap2.parentNode.removeChild(wrap2);
      view.focus();
    }, 50);
  }
  var brokenClipboardAPI = ios && webkit_version < 604;
  handlers.copy = editHandlers.cut = (view, _event) => {
    let event = _event;
    let sel = view.state.selection, cut = event.type == "cut";
    if (sel.empty)
      return;
    let data = brokenClipboardAPI ? null : event.clipboardData;
    let slice2 = sel.content(), { dom, text } = serializeForClipboard(view, slice2);
    if (data) {
      event.preventDefault();
      data.clearData();
      data.setData("text/html", dom.innerHTML);
      data.setData("text/plain", text);
    } else {
      captureCopy(view, dom);
    }
    if (cut)
      view.dispatch(view.state.tr.deleteSelection().scrollIntoView().setMeta("uiEvent", "cut"));
  };
  function sliceSingleNode(slice2) {
    return slice2.openStart == 0 && slice2.openEnd == 0 && slice2.content.childCount == 1 ? slice2.content.firstChild : null;
  }
  function capturePaste(view, event) {
    if (!view.dom.parentNode)
      return;
    let plainText = view.input.shiftKey || view.state.selection.$from.parent.type.spec.code;
    let target = view.dom.parentNode.appendChild(document.createElement(plainText ? "textarea" : "div"));
    if (!plainText)
      target.contentEditable = "true";
    target.style.cssText = "position: fixed; left: -10000px; top: 10px";
    target.focus();
    let plain = view.input.shiftKey && view.input.lastKeyCode != 45;
    setTimeout(() => {
      view.focus();
      if (target.parentNode)
        target.parentNode.removeChild(target);
      if (plainText)
        doPaste(view, target.value, null, plain, event);
      else
        doPaste(view, target.textContent, target.innerHTML, plain, event);
    }, 50);
  }
  function doPaste(view, text, html, preferPlain, event) {
    let slice2 = parseFromClipboard(view, text, html, preferPlain, view.state.selection.$from);
    if (view.someProp("handlePaste", (f) => f(view, event, slice2 || Slice.empty)))
      return true;
    if (!slice2)
      return false;
    let singleNode = sliceSingleNode(slice2);
    let tr = singleNode ? view.state.tr.replaceSelectionWith(singleNode, preferPlain) : view.state.tr.replaceSelection(slice2);
    view.dispatch(tr.scrollIntoView().setMeta("paste", true).setMeta("uiEvent", "paste"));
    return true;
  }
  function getText(clipboardData) {
    let text = clipboardData.getData("text/plain") || clipboardData.getData("Text");
    if (text)
      return text;
    let uris = clipboardData.getData("text/uri-list");
    return uris ? uris.replace(/\r?\n/g, " ") : "";
  }
  editHandlers.paste = (view, _event) => {
    let event = _event;
    if (view.composing && !android)
      return;
    let data = brokenClipboardAPI ? null : event.clipboardData;
    let plain = view.input.shiftKey && view.input.lastKeyCode != 45;
    if (data && doPaste(view, getText(data), data.getData("text/html"), plain, event))
      event.preventDefault();
    else
      capturePaste(view, event);
  };
  var Dragging = class {
    constructor(slice2, move, node) {
      this.slice = slice2;
      this.move = move;
      this.node = node;
    }
  };
  var dragCopyModifier = mac ? "altKey" : "ctrlKey";
  function dragMoves(view, event) {
    let copy2;
    view.someProp("dragCopies", (test) => {
      copy2 = copy2 || test(event);
    });
    return copy2 != null ? !copy2 : !event[dragCopyModifier];
  }
  handlers.dragstart = (view, _event) => {
    let event = _event;
    let mouseDown = view.input.mouseDown;
    if (mouseDown)
      mouseDown.done();
    if (!event.dataTransfer)
      return;
    let sel = view.state.selection;
    let pos = sel.empty ? null : view.posAtCoords(eventCoords(event));
    let node;
    if (pos && pos.pos >= sel.from && pos.pos <= (sel instanceof NodeSelection ? sel.to - 1 : sel.to)) ;
    else if (mouseDown && typeof mouseDown.mightDrag == "object") {
      node = NodeSelection.create(view.state.doc, mouseDown.mightDrag.pos);
    } else if (event.target && isElt(event.target)) {
      let desc = view.docView.nearestDesc(event.target, true);
      if (desc && desc.node.type.spec.draggable && desc != view.docView)
        node = NodeSelection.create(view.state.doc, desc.posBefore);
    }
    let draggedSlice = (node || view.state.selection).content();
    let { dom, text, slice: slice2 } = serializeForClipboard(view, draggedSlice);
    if (!event.dataTransfer.files.length || !chrome || chrome_version > 120)
      event.dataTransfer.clearData();
    event.dataTransfer.setData(brokenClipboardAPI ? "Text" : "text/html", dom.innerHTML);
    event.dataTransfer.effectAllowed = "copyMove";
    if (!brokenClipboardAPI)
      event.dataTransfer.setData("text/plain", text);
    view.dragging = new Dragging(slice2, dragMoves(view, event), node);
  };
  handlers.dragend = (view) => {
    let dragging = view.dragging;
    window.setTimeout(() => {
      if (view.dragging == dragging)
        view.dragging = null;
    }, 50);
  };
  editHandlers.dragover = editHandlers.dragenter = (_, e) => e.preventDefault();
  editHandlers.drop = (view, event) => {
    try {
      handleDrop(view, event, view.dragging);
    } finally {
      view.dragging = null;
    }
  };
  function handleDrop(view, event, dragging) {
    if (!event.dataTransfer)
      return;
    let eventPos = view.posAtCoords(eventCoords(event));
    if (!eventPos)
      return;
    let $mouse = view.state.doc.resolve(eventPos.pos);
    let slice2 = dragging && dragging.slice;
    if (slice2) {
      view.someProp("transformPasted", (f) => {
        slice2 = f(slice2, view, false);
      });
    } else {
      slice2 = parseFromClipboard(view, getText(event.dataTransfer), brokenClipboardAPI ? null : event.dataTransfer.getData("text/html"), false, $mouse);
    }
    let move = !!(dragging && dragMoves(view, event));
    if (view.someProp("handleDrop", (f) => f(view, event, slice2 || Slice.empty, move))) {
      event.preventDefault();
      return;
    }
    if (!slice2)
      return;
    event.preventDefault();
    let insertPos = slice2 ? dropPoint(view.state.doc, $mouse.pos, slice2) : $mouse.pos;
    if (insertPos == null)
      insertPos = $mouse.pos;
    let tr = view.state.tr;
    if (move) {
      let { node } = dragging;
      if (node)
        node.replace(tr);
      else
        tr.deleteSelection();
    }
    let pos = tr.mapping.map(insertPos);
    let isNode = slice2.openStart == 0 && slice2.openEnd == 0 && slice2.content.childCount == 1;
    let beforeInsert = tr.doc;
    if (isNode)
      tr.replaceRangeWith(pos, pos, slice2.content.firstChild);
    else
      tr.replaceRange(pos, pos, slice2);
    if (tr.doc.eq(beforeInsert))
      return;
    let $pos = tr.doc.resolve(pos);
    if (isNode && NodeSelection.isSelectable(slice2.content.firstChild) && $pos.nodeAfter && $pos.nodeAfter.sameMarkup(slice2.content.firstChild)) {
      tr.setSelection(new NodeSelection($pos));
    } else {
      let end = tr.mapping.map(insertPos);
      tr.mapping.maps[tr.mapping.maps.length - 1].forEach((_from, _to, _newFrom, newTo) => end = newTo);
      tr.setSelection(selectionBetween(view, $pos, tr.doc.resolve(end)));
    }
    view.focus();
    view.dispatch(tr.setMeta("uiEvent", "drop"));
  }
  handlers.focus = (view) => {
    view.input.lastFocus = Date.now();
    if (!view.focused) {
      view.domObserver.stopped(() => view.dom.classList.add("ProseMirror-focused"));
      view.focused = true;
      view.domSel.read();
      if (!view.domSel.synced) {
        let startSel = view.domSel.range;
        setTimeout(() => {
          let curSel = view.domSel.readRange();
          if (curSel && startSel.eq(curSel))
            view.domSel.sync();
        }, 20);
      }
    }
  };
  handlers.blur = (view, _event) => {
    let event = _event;
    if (view.focused) {
      view.domObserver.stopped(() => view.dom.classList.remove("ProseMirror-focused"));
      if (event.relatedTarget && view.dom.contains(event.relatedTarget))
        view.domSel.deactivate();
      view.focused = false;
    }
  };
  handlers.beforeinput = (view, _event) => {
    let event = _event;
    if (android && event.inputType == "deleteContentBackward") {
      view.domObserver.flushSoon();
      let { domChangeCount } = view.input;
      setTimeout(() => {
        if (view.input.domChangeCount != domChangeCount || view.domObserver.pendingRecords().length)
          return;
        view.dom.blur();
        view.focus();
        if (dispatchKey(view, "Backspace"))
          return;
        let { $cursor } = view.state.selection;
        if ($cursor && $cursor.pos > 0)
          view.dispatch(view.state.tr.delete($cursor.pos - 1, $cursor.pos).scrollIntoView());
      }, 50);
    }
  };
  for (let prop in editHandlers)
    handlers[prop] = editHandlers[prop];
  function compareObjs(a, b) {
    if (a == b)
      return true;
    for (let p in a)
      if (a[p] !== b[p])
        return false;
    for (let p in b)
      if (!(p in a))
        return false;
    return true;
  }
  var FragmentCursor = class {
    constructor(frag) {
      this.frag = frag;
      this.index = 0;
      this.off = 0;
    }
    nodeAt(off) {
      while (this.off <= off && this.index < this.frag.childCount) {
        let next = this.frag.child(this.index);
        if (this.off == off)
          return next;
        this.off += next.nodeSize;
        this.index++;
      }
      return null;
    }
  };
  var WidgetType = class _WidgetType {
    constructor(toDOM, spec) {
      this.toDOM = toDOM;
      this.spec = spec || noSpec;
      this.side = this.spec.side || 0;
    }
    map(mapping, span, offset, oldOffset) {
      let { pos, deleted } = mapping.mapResult(span.from + oldOffset, this.side < 0 ? -1 : 1);
      return deleted ? null : new Decoration(pos - offset, pos - offset, this);
    }
    valid() {
      return true;
    }
    eq(other) {
      return this == other || other instanceof _WidgetType && (this.spec.key && this.spec.key == other.spec.key || this.toDOM == other.toDOM && compareObjs(this.spec, other.spec));
    }
    destroy(node) {
      if (this.spec.destroy)
        this.spec.destroy(node);
    }
  };
  var InlineType = class _InlineType {
    constructor(attrs, spec) {
      this.attrs = attrs;
      this.spec = spec || noSpec;
    }
    map(mapping, span, offset, oldOffset) {
      let from2 = mapping.map(span.from + oldOffset, this.spec.inclusiveStart ? -1 : 1) - offset;
      let to = mapping.map(span.to + oldOffset, this.spec.inclusiveEnd ? 1 : -1) - offset;
      return from2 >= to ? null : new Decoration(from2, to, this);
    }
    valid(_, span) {
      return span.from < span.to;
    }
    eq(other) {
      return this == other || other instanceof _InlineType && compareObjs(this.attrs, other.attrs) && compareObjs(this.spec, other.spec);
    }
    static is(span) {
      return span.type instanceof _InlineType;
    }
    destroy() {
    }
  };
  var NodeType2 = class _NodeType {
    constructor(attrs, spec) {
      this.attrs = attrs;
      this.spec = spec || noSpec;
    }
    map(mapping, span, offset, oldOffset) {
      let from2 = mapping.mapResult(span.from + oldOffset, 1);
      if (from2.deleted)
        return null;
      let to = mapping.mapResult(span.to + oldOffset, -1);
      if (to.deleted || to.pos <= from2.pos)
        return null;
      return new Decoration(from2.pos - offset, to.pos - offset, this);
    }
    valid(node, span, cursor) {
      let found2 = cursor.nodeAt(span.from);
      return !!found2 && !found2.isText && span.from + found2.nodeSize == span.to;
    }
    eq(other) {
      return this == other || other instanceof _NodeType && compareObjs(this.attrs, other.attrs) && compareObjs(this.spec, other.spec);
    }
    destroy() {
    }
  };
  var Decoration = class _Decoration {
    /**
    @internal
    */
    constructor(from2, to, type) {
      this.from = from2;
      this.to = to;
      this.type = type;
    }
    /**
    @internal
    */
    copy(from2, to) {
      return new _Decoration(from2, to, this.type);
    }
    /**
    @internal
    */
    eq(other, offset = 0) {
      return this.type.eq(other.type) && this.from + offset == other.from && this.to + offset == other.to;
    }
    /**
    @internal
    */
    map(mapping, offset, oldOffset) {
      return this.type.map(mapping, this, offset, oldOffset);
    }
    /**
    Creates a widget decoration, which is a DOM node that's shown in
    the document at the given position. It is recommended that you
    delay rendering the widget by passing a function that will be
    called when the widget is actually drawn in a view, but you can
    also directly pass a DOM node. `getPos` can be used to find the
    widget's current document position.
    */
    static widget(pos, toDOM, spec) {
      return new _Decoration(pos, pos, new WidgetType(toDOM, spec));
    }
    /**
    Creates an inline decoration, which adds the given attributes to
    each inline node between `from` and `to`.
    */
    static inline(from2, to, attrs, spec) {
      return new _Decoration(from2, to, new InlineType(attrs, spec));
    }
    /**
    Creates a node decoration. `from` and `to` should point precisely
    before and after a node in the document. That node, and only that
    node, will receive the given attributes.
    */
    static node(from2, to, attrs, spec) {
      return new _Decoration(from2, to, new NodeType2(attrs, spec));
    }
    /**
    The spec provided when creating this decoration. Can be useful
    if you've stored extra information in that object.
    */
    get spec() {
      return this.type.spec;
    }
    /**
    @internal
    */
    get inline() {
      return this.type instanceof InlineType;
    }
    /**
    @internal
    */
    get widget() {
      return this.type instanceof WidgetType;
    }
  };
  var none = [];
  var noSpec = {};
  var DecorationSet = class _DecorationSet {
    /**
    @internal
    */
    constructor(local, children) {
      this.local = local.length ? local : none;
      this.children = children.length ? children : none;
    }
    /**
    Create a set of decorations, using the structure of the given
    document. This will consume (modify) the `decorations` array, so
    you must make a copy if you want need to preserve that.
    */
    static create(doc3, decorations) {
      return decorations.length ? buildTree(decorations, doc3, 0, noSpec) : empty;
    }
    /**
    Find all decorations in this set which touch the given range
    (including decorations that start or end directly at the
    boundaries) and match the given predicate on their spec. When
    `start` and `end` are omitted, all decorations in the set are
    considered. When `predicate` isn't given, all decorations are
    assumed to match.
    */
    find(start, end, predicate) {
      let result = [];
      this.findInner(start == null ? 0 : start, end == null ? 1e9 : end, result, 0, predicate);
      return result;
    }
    findInner(start, end, result, offset, predicate) {
      for (let i = 0; i < this.local.length; i++) {
        let span = this.local[i];
        if (span.from > end)
          break;
        if (span.to >= start && (!predicate || predicate(span.spec)))
          result.push(span.copy(span.from + offset, span.to + offset));
      }
      for (let i = 0; i < this.children.length; i += 3) {
        if (this.children[i] >= end)
          break;
        if (this.children[i + 1] > start) {
          let childOff = this.children[i] + 1;
          this.children[i + 2].findInner(start - childOff, end - childOff, result, offset + childOff, predicate);
        }
      }
    }
    /**
    Map the set of decorations in response to a change in the
    document.
    */
    map(mapping, doc3, options) {
      if (this == empty || mapping.maps.length == 0)
        return this;
      return this.mapInner(mapping, doc3, 0, 0, options || noSpec);
    }
    /**
    @internal
    */
    mapInner(mapping, node, offset, oldOffset, options) {
      let newLocal;
      if (this.local.length) {
        let cur = new FragmentCursor(node.content);
        for (let i = 0; i < this.local.length; i++) {
          let mapped = this.local[i].map(mapping, offset, oldOffset);
          if (mapped && mapped.type.valid(node, mapped, cur))
            (newLocal || (newLocal = [])).push(mapped);
          else if (options.onRemove)
            options.onRemove(this.local[i].spec);
        }
      }
      if (this.children.length)
        return mapChildren(this.children, newLocal || [], mapping, node, offset, oldOffset, options);
      else
        return newLocal ? new _DecorationSet(newLocal.sort(byPos), none) : empty;
    }
    /**
    Add the given array of decorations to the ones in the set,
    producing a new set. Consumes the `decorations` array. Needs
    access to the current document to create the appropriate tree
    structure.
    */
    add(doc3, decorations) {
      if (!decorations.length)
        return this;
      if (this == empty)
        return _DecorationSet.create(doc3, decorations);
      return this.addInner(doc3, decorations, 0);
    }
    addInner(doc3, decorations, offset) {
      let children, childIndex = 0;
      doc3.forEach((childNode, childOffset) => {
        let baseOffset = childOffset + offset, found2;
        if (!(found2 = takeSpansForNode(decorations, childNode, baseOffset)))
          return;
        if (!children)
          children = this.children.slice();
        while (childIndex < children.length && children[childIndex] < childOffset)
          childIndex += 3;
        if (children[childIndex] == childOffset)
          children[childIndex + 2] = children[childIndex + 2].addInner(childNode, found2, baseOffset + 1);
        else
          children.splice(childIndex, 0, childOffset, childOffset + childNode.nodeSize, buildTree(found2, childNode, baseOffset + 1, noSpec));
        childIndex += 3;
      });
      let local = moveSpans(childIndex ? withoutNulls(decorations) : decorations, -offset).sort(byPos);
      if (local.length) {
        let cur = new FragmentCursor(doc3.content);
        for (let i = 0; i < local.length; i++)
          if (!local[i].type.valid(doc3, local[i], cur))
            local.splice(i--, 1);
      }
      return new _DecorationSet(local.length ? this.local.concat(local).sort(byPos) : this.local, children || this.children);
    }
    /**
    Create a new set that contains the decorations in this set, minus
    the ones in the given array.
    */
    remove(decorations) {
      if (decorations.length == 0 || this == empty)
        return this;
      return this.removeInner(decorations, 0);
    }
    removeInner(decorations, offset) {
      let children = this.children, local = this.local;
      for (let i = 0; i < children.length; i += 3) {
        let found2;
        let from2 = children[i] + offset, to = children[i + 1] + offset;
        for (let j = 0, span; j < decorations.length; j++)
          if (span = decorations[j]) {
            if (span.from > from2 && span.to < to) {
              decorations[j] = null;
              (found2 || (found2 = [])).push(span);
            }
          }
        if (!found2)
          continue;
        if (children == this.children)
          children = this.children.slice();
        let removed = children[i + 2].removeInner(found2, from2 + 1);
        if (removed != empty) {
          children[i + 2] = removed;
        } else {
          children.splice(i, 3);
          i -= 3;
        }
      }
      if (local.length) {
        for (let i = 0, span; i < decorations.length; i++)
          if (span = decorations[i]) {
            for (let j = 0; j < local.length; j++)
              if (local[j].eq(span, offset)) {
                if (local == this.local)
                  local = this.local.slice();
                local.splice(j--, 1);
              }
          }
      }
      if (children == this.children && local == this.local)
        return this;
      return local.length || children.length ? new _DecorationSet(local, children) : empty;
    }
    forChild(offset, node) {
      if (this == empty)
        return this;
      if (node.isLeaf)
        return _DecorationSet.empty;
      let child, local;
      let low = 0, high = this.children.length / 3;
      while (low < high) {
        let mid = low + high >>> 1, index = mid * 3, start2 = this.children[index];
        if (start2 < offset) {
          low = mid + 1;
        } else if (start2 > offset) {
          high = mid;
        } else {
          child = this.children[index + 2];
          break;
        }
      }
      let start = offset + 1, end = start + node.content.size;
      for (let i = 0; i < this.local.length; i++) {
        let dec = this.local[i];
        if (dec.from < end && dec.to > start && dec.type instanceof InlineType) {
          let from2 = Math.max(start, dec.from) - start, to = Math.min(end, dec.to) - start;
          if (from2 < to)
            (local || (local = [])).push(dec.copy(from2, to));
        }
      }
      if (local) {
        let localSet = new _DecorationSet(local.sort(byPos), none);
        return child ? new DecorationGroup([localSet, child]) : localSet;
      }
      return child || empty;
    }
    /**
    @internal
    */
    eq(other) {
      if (this == other)
        return true;
      if (!(other instanceof _DecorationSet) || this.local.length != other.local.length || this.children.length != other.children.length)
        return false;
      for (let i = 0; i < this.local.length; i++)
        if (!this.local[i].eq(other.local[i]))
          return false;
      for (let i = 0; i < this.children.length; i += 3)
        if (this.children[i] != other.children[i] || this.children[i + 1] != other.children[i + 1] || !this.children[i + 2].eq(other.children[i + 2]))
          return false;
      return true;
    }
    /**
    @internal
    */
    locals(node) {
      return removeOverlap(this.localsInner(node));
    }
    /**
    @internal
    */
    localsInner(node) {
      if (this == empty)
        return none;
      if (node.inlineContent || !this.local.some(InlineType.is))
        return this.local;
      let result = [];
      for (let i = 0; i < this.local.length; i++) {
        if (!(this.local[i].type instanceof InlineType))
          result.push(this.local[i]);
      }
      return result;
    }
    forEachSet(f) {
      f(this);
    }
  };
  DecorationSet.empty = new DecorationSet([], []);
  DecorationSet.removeOverlap = removeOverlap;
  var empty = DecorationSet.empty;
  var DecorationGroup = class _DecorationGroup {
    constructor(members) {
      this.members = members;
    }
    map(mapping, doc3) {
      const mappedDecos = this.members.map((member) => member.map(mapping, doc3, noSpec));
      return _DecorationGroup.from(mappedDecos);
    }
    forChild(offset, child) {
      if (child.isLeaf)
        return DecorationSet.empty;
      let found2 = [];
      for (let i = 0; i < this.members.length; i++) {
        let result = this.members[i].forChild(offset, child);
        if (result == empty)
          continue;
        if (result instanceof _DecorationGroup)
          found2 = found2.concat(result.members);
        else
          found2.push(result);
      }
      return _DecorationGroup.from(found2);
    }
    eq(other) {
      if (!(other instanceof _DecorationGroup) || other.members.length != this.members.length)
        return false;
      for (let i = 0; i < this.members.length; i++)
        if (!this.members[i].eq(other.members[i]))
          return false;
      return true;
    }
    locals(node) {
      let result, sorted = true;
      for (let i = 0; i < this.members.length; i++) {
        let locals = this.members[i].localsInner(node);
        if (!locals.length)
          continue;
        if (!result) {
          result = locals;
        } else {
          if (sorted) {
            result = result.slice();
            sorted = false;
          }
          for (let j = 0; j < locals.length; j++)
            result.push(locals[j]);
        }
      }
      return result ? removeOverlap(sorted ? result : result.sort(byPos)) : none;
    }
    // Create a group for the given array of decoration sets, or return
    // a single set when possible.
    static from(members) {
      switch (members.length) {
        case 0:
          return empty;
        case 1:
          return members[0];
        default:
          return new _DecorationGroup(members.every((m) => m instanceof DecorationSet) ? members : members.reduce((r, m) => r.concat(m instanceof DecorationSet ? m : m.members), []));
      }
    }
    forEachSet(f) {
      for (let i = 0; i < this.members.length; i++)
        this.members[i].forEachSet(f);
    }
  };
  function mapChildren(oldChildren, newLocal, mapping, node, offset, oldOffset, options) {
    let children = oldChildren.slice();
    for (let i = 0, baseOffset = oldOffset; i < mapping.maps.length; i++) {
      let moved = 0;
      mapping.maps[i].forEach((oldStart, oldEnd, newStart, newEnd) => {
        let dSize = newEnd - newStart - (oldEnd - oldStart);
        for (let i2 = 0; i2 < children.length; i2 += 3) {
          let end = children[i2 + 1];
          if (end < 0 || oldStart > end + baseOffset - moved)
            continue;
          let start = children[i2] + baseOffset - moved;
          if (oldEnd >= start) {
            children[i2 + 1] = oldStart <= start ? -2 : -1;
          } else if (oldStart >= baseOffset && dSize) {
            children[i2] += dSize;
            children[i2 + 1] += dSize;
          }
        }
        moved += dSize;
      });
      baseOffset = mapping.maps[i].map(baseOffset, -1);
    }
    let mustRebuild = false;
    for (let i = 0; i < children.length; i += 3)
      if (children[i + 1] < 0) {
        if (children[i + 1] == -2) {
          mustRebuild = true;
          children[i + 1] = -1;
          continue;
        }
        let from2 = mapping.map(oldChildren[i] + oldOffset), fromLocal = from2 - offset;
        if (fromLocal < 0 || fromLocal >= node.content.size) {
          mustRebuild = true;
          continue;
        }
        let to = mapping.map(oldChildren[i + 1] + oldOffset, -1), toLocal = to - offset;
        let { index, offset: childOffset } = node.content.findIndex(fromLocal);
        let childNode = node.maybeChild(index);
        if (childNode && childOffset == fromLocal && childOffset + childNode.nodeSize == toLocal) {
          let mapped = children[i + 2].mapInner(mapping, childNode, from2 + 1, oldChildren[i] + oldOffset + 1, options);
          if (mapped != empty) {
            children[i] = fromLocal;
            children[i + 1] = toLocal;
            children[i + 2] = mapped;
          } else {
            children[i + 1] = -2;
            mustRebuild = true;
          }
        } else {
          mustRebuild = true;
        }
      }
    if (mustRebuild) {
      let decorations = mapAndGatherRemainingDecorations(children, oldChildren, newLocal, mapping, offset, oldOffset, options);
      let built = buildTree(decorations, node, 0, options);
      newLocal = built.local;
      for (let i = 0; i < children.length; i += 3)
        if (children[i + 1] < 0) {
          children.splice(i, 3);
          i -= 3;
        }
      for (let i = 0, j = 0; i < built.children.length; i += 3) {
        let from2 = built.children[i];
        while (j < children.length && children[j] < from2)
          j += 3;
        children.splice(j, 0, built.children[i], built.children[i + 1], built.children[i + 2]);
      }
    }
    return new DecorationSet(newLocal.sort(byPos), children);
  }
  function moveSpans(spans, offset) {
    if (!offset || !spans.length)
      return spans;
    let result = [];
    for (let i = 0; i < spans.length; i++) {
      let span = spans[i];
      result.push(new Decoration(span.from + offset, span.to + offset, span.type));
    }
    return result;
  }
  function mapAndGatherRemainingDecorations(children, oldChildren, decorations, mapping, offset, oldOffset, options) {
    function gather(set, oldOffset2) {
      for (let i = 0; i < set.local.length; i++) {
        let mapped = set.local[i].map(mapping, offset, oldOffset2);
        if (mapped)
          decorations.push(mapped);
        else if (options.onRemove)
          options.onRemove(set.local[i].spec);
      }
      for (let i = 0; i < set.children.length; i += 3)
        gather(set.children[i + 2], set.children[i] + oldOffset2 + 1);
    }
    for (let i = 0; i < children.length; i += 3)
      if (children[i + 1] == -1)
        gather(children[i + 2], oldChildren[i] + oldOffset + 1);
    return decorations;
  }
  function takeSpansForNode(spans, node, offset) {
    if (node.isLeaf)
      return null;
    let end = offset + node.nodeSize, found2 = null;
    for (let i = 0, span; i < spans.length; i++) {
      if ((span = spans[i]) && span.from > offset && span.to < end) {
        (found2 || (found2 = [])).push(span);
        spans[i] = null;
      }
    }
    return found2;
  }
  function withoutNulls(array) {
    let result = [];
    for (let i = 0; i < array.length; i++)
      if (array[i] != null)
        result.push(array[i]);
    return result;
  }
  function buildTree(spans, node, offset, options) {
    let children = [], hasNulls = false;
    node.forEach((childNode, localStart) => {
      let found2 = takeSpansForNode(spans, childNode, localStart + offset);
      if (found2) {
        hasNulls = true;
        let subtree = buildTree(found2, childNode, offset + localStart + 1, options);
        if (subtree != empty)
          children.push(localStart, localStart + childNode.nodeSize, subtree);
      }
    });
    let locals = moveSpans(hasNulls ? withoutNulls(spans) : spans, -offset).sort(byPos);
    if (locals.length) {
      let cur = new FragmentCursor(node.content);
      for (let i = 0; i < locals.length; i++)
        if (!locals[i].type.valid(node, locals[i], cur)) {
          if (options.onRemove)
            options.onRemove(locals[i].spec);
          locals.splice(i--, 1);
        }
    }
    return locals.length || children.length ? new DecorationSet(locals, children) : empty;
  }
  function byPos(a, b) {
    return a.from - b.from || a.to - b.to;
  }
  function removeOverlap(spans) {
    let working = spans;
    for (let i = 0; i < working.length - 1; i++) {
      let span = working[i];
      if (span.from != span.to)
        for (let j = i + 1; j < working.length; j++) {
          let next = working[j];
          if (next.from == span.from) {
            if (next.to != span.to) {
              if (working == spans)
                working = spans.slice();
              working[j] = next.copy(next.from, span.to);
              insertAhead(working, j + 1, next.copy(span.to, next.to));
            }
            continue;
          } else {
            if (next.from < span.to) {
              if (working == spans)
                working = spans.slice();
              working[i] = span.copy(span.from, next.from);
              insertAhead(working, j, span.copy(next.from, span.to));
            }
            break;
          }
        }
    }
    return working;
  }
  function insertAhead(array, i, deco) {
    while (i < array.length && byPos(deco, array[i]) > 0)
      i++;
    array.splice(i, 0, deco);
  }
  function viewDecorations(view) {
    let found2 = [];
    view.someProp("decorations", (f) => {
      let result = f(view.state);
      if (result && result != empty)
        found2.push(result);
    });
    if (view.cursorWrapper)
      found2.push(DecorationSet.create(view.state.doc, [view.cursorWrapper.deco]));
    return DecorationGroup.from(found2);
  }
  function parseBetween(view, from_, to_, addedNodes) {
    let { node: parent, fromOffset, toOffset, from: from2, to } = view.docView.parseRange(from_, to_);
    let domSel = view.domSel.range;
    let find;
    let anchor = domSel.anchorNode;
    if (anchor && contains(view.dom, anchor)) {
      find = [{ node: anchor, offset: domSel.anchorOffset }];
      if (!selectionCollapsed(domSel))
        find.push({ node: domSel.focusNode, offset: domSel.focusOffset });
    }
    if (chrome && view.input.lastKeyCode === 8) {
      for (let off = toOffset; off > fromOffset; off--) {
        let node = parent.childNodes[off - 1], desc = node.pmViewDesc;
        if (node.nodeName == "BR" && !desc) {
          toOffset = off;
          break;
        }
        if (!desc || desc.size)
          break;
      }
    }
    let startDoc = view.state.doc;
    let parser = view.someProp("domParser") || DOMParser.fromSchema(view.state.schema);
    let $from = startDoc.resolve(from2);
    let sel = null, doc3 = parser.parse(parent, {
      topNode: $from.parent,
      topMatch: $from.parent.contentMatchAt($from.index()),
      topOpen: true,
      from: fromOffset,
      to: toOffset,
      preserveWhitespace: $from.parent.type.whitespace == "pre" ? "full" : true,
      findPositions: find,
      ruleFromNode: ruleFromNode(addedNodes),
      context: $from
    });
    if (find && find[0].pos != null) {
      let anchor2 = find[0].pos, head = find[1] && find[1].pos;
      if (head == null)
        head = anchor2;
      sel = { anchor: anchor2 + from2, head: head + from2 };
    }
    return { doc: doc3, sel, from: from2, to };
  }
  var ruleFromNode = (added) => (dom) => {
    let desc = dom.pmViewDesc;
    if (desc) {
      return desc.parseRule(added);
    } else if (dom.nodeName == "BR" && dom.parentNode) {
      if (safari && /^(ul|ol)$/i.test(dom.parentNode.nodeName)) {
        let skip = document.createElement("div");
        skip.appendChild(document.createElement("li"));
        return { skip };
      } else if (dom.parentNode.lastChild == dom || safari && /^(tr|table)$/i.test(dom.parentNode.nodeName)) {
        return { ignore: true };
      }
    } else if (dom.nodeName == "IMG" && dom.getAttribute("mark-placeholder")) {
      return { ignore: true };
    }
    return null;
  };
  var isInline = /^(a|abbr|acronym|b|bd[io]|big|br|button|cite|code|data(list)?|del|dfn|em|i|img|ins|kbd|label|map|mark|meter|output|q|ruby|s|samp|small|span|strong|su[bp]|time|u|tt|var)$/i;
  function readDOMChange(view, from2, to, selChange, typeOver, addedNodes) {
    let compositionID = view.input.compositionPendingChanges || (view.composing ? view.input.compositionID : 0);
    view.input.compositionPendingChanges = 0;
    if (from2 < 0) {
      let origin = view.input.lastSelectionTime > Date.now() - 50 ? view.input.lastSelectionOrigin : null;
      let newSel = selectionFromDOM(view, view.domSel.range, origin);
      if (newSel && !view.state.selection.eq(newSel) && view.domSel.active) {
        if (chrome && android && view.input.lastKeyCode === 13 && Date.now() - 100 < view.input.lastKeyCodeTime && dispatchKey(view, "Enter"))
          return;
        let tr = view.state.tr.setSelection(newSel);
        if (origin == "pointer")
          tr.setMeta("pointer", true);
        else if (origin == "key")
          tr.scrollIntoView();
        if (compositionID)
          tr.setMeta("composition", compositionID);
        view.dispatch(tr);
      }
      return;
    }
    let $before = view.state.doc.resolve(from2);
    let shared = $before.sharedDepth(to);
    from2 = $before.before(shared + 1);
    to = view.state.doc.resolve(to).after(shared + 1);
    let sel = view.state.selection;
    let parse = parseBetween(view, from2, to, addedNodes);
    let doc3 = view.state.doc, compare = doc3.slice(parse.from, parse.to);
    let preferredPos, preferredSide;
    if (view.input.lastKeyCode === 8 && Date.now() - 100 < view.input.lastKeyCodeTime) {
      preferredPos = view.state.selection.to;
      preferredSide = "end";
    } else {
      preferredPos = view.state.selection.from;
      preferredSide = "start";
    }
    view.input.lastKeyCode = null;
    let change = findDiff(compare.content, parse.doc.content, parse.from, preferredPos, preferredSide);
    if (change)
      view.input.domChangeCount++;
    if ((ios && view.input.lastIOSEnter > Date.now() - 225 || android) && addedNodes.some((n) => isElt(n) && !isInline.test(n.nodeName)) && (!change || change.endA >= change.endB) && dispatchKey(view, "Enter")) {
      view.input.lastIOSEnter = 0;
      return;
    }
    if (!change) {
      if (typeOver && sel instanceof TextSelection && !sel.empty && sel.$head.sameParent(sel.$anchor) && !view.composing && !(parse.sel && parse.sel.anchor != parse.sel.head)) {
        change = { start: sel.from, endA: sel.to, endB: sel.to };
      } else {
        if (parse.sel) {
          let sel2 = resolveSelection(view, view.state.doc, parse.sel);
          if (sel2 && !sel2.eq(view.state.selection)) {
            let tr = view.state.tr.setSelection(sel2);
            if (compositionID)
              tr.setMeta("composition", compositionID);
            view.dispatch(tr);
          }
        }
        return;
      }
    }
    if (view.state.selection.from < view.state.selection.to && change.start == change.endB && view.state.selection instanceof TextSelection) {
      if (change.start > view.state.selection.from && change.start <= view.state.selection.from + 2 && view.state.selection.from >= parse.from) {
        change.start = view.state.selection.from;
      } else if (change.endA < view.state.selection.to && change.endA >= view.state.selection.to - 2 && view.state.selection.to <= parse.to) {
        change.endB += view.state.selection.to - change.endA;
        change.endA = view.state.selection.to;
      }
    }
    let $from = parse.doc.resolveNoCache(change.start - parse.from);
    let $to = parse.doc.resolveNoCache(change.endB - parse.from);
    let $fromA = doc3.resolve(change.start);
    let inlineChange = $from.sameParent($to) && $from.parent.inlineContent && $fromA.end() >= change.endA;
    if ((ios && view.input.lastIOSEnter > Date.now() - 225 && (!inlineChange || addedNodes.some((n) => n.nodeName == "DIV" || n.nodeName == "P")) || !inlineChange && looksLikeEnter(parse.doc, $from.pos, $to.pos)) && dispatchKey(view, "Enter")) {
      view.input.lastIOSEnter = 0;
      return;
    }
    if (view.state.selection.anchor > change.start && (inlineChange ? change.endA > change.start && change.endB == change.start : looksLikeBlockJoin(doc3, change.start, change.endA, $from, $to)) && dispatchKey(view, "Backspace")) {
      if (android && chrome)
        view.domSel.suppressChanges();
      return;
    }
    if (chrome && change.endB == change.start)
      view.input.lastChromeDelete = Date.now();
    if (android && !inlineChange && $from.start() != $to.start() && $to.parentOffset == 0 && $from.depth == $to.depth && parse.sel && parse.sel.anchor == parse.sel.head && parse.sel.head == change.endA) {
      change.endB -= 2;
      $to = parse.doc.resolveNoCache(change.endB - parse.from);
      setTimeout(() => dispatchKey(view, "Enter"), 20);
    }
    let chFrom = change.start, chTo = change.endA;
    let mkTr = (base2) => {
      let tr = base2 || view.state.tr.replace(chFrom, chTo, parse.doc.slice(change.start - parse.from, change.endB - parse.from));
      if (parse.sel) {
        let sel2 = resolveSelection(view, tr.doc, parse.sel);
        if (sel2 && !(chrome && view.composing && sel2.empty && (change.start != change.endB || view.input.lastChromeDelete < Date.now() - 100) && (sel2.head == chFrom || sel2.head == tr.mapping.map(chTo) - 1)))
          tr.setSelection(sel2);
      }
      if (compositionID)
        tr.setMeta("composition", compositionID);
      return tr.scrollIntoView();
    };
    let markChange;
    if (inlineChange) {
      if ($from.pos == $to.pos) {
        let tr = mkTr(view.state.tr.delete(chFrom, chTo));
        let marks2 = doc3.resolve(change.start).marksAcross(doc3.resolve(change.endA));
        if (marks2)
          tr.ensureMarks(marks2);
        view.dispatch(tr);
      } else if (
        // Adding or removing a mark
        change.endA == change.endB && (markChange = isMarkChange($from.parent.content.cut($from.parentOffset, $to.parentOffset), $fromA.parent.content.cut($fromA.parentOffset, change.endA - $fromA.start())))
      ) {
        let tr = mkTr(view.state.tr);
        if (markChange.type == "add")
          tr.addMark(chFrom, chTo, markChange.mark);
        else
          tr.removeMark(chFrom, chTo, markChange.mark);
        view.dispatch(tr);
      } else if ($from.parent.child($from.index()).isText && $from.index() == $to.index() - ($to.textOffset ? 0 : 1)) {
        let text = $from.parent.textBetween($from.parentOffset, $to.parentOffset);
        let deflt = () => mkTr(view.state.tr.insertText(text, chFrom, chTo));
        if (!view.someProp("handleTextInput", (f) => f(view, chFrom, chTo, text, deflt)))
          view.dispatch(deflt());
      } else {
        view.dispatch(mkTr());
      }
    } else {
      view.dispatch(mkTr());
    }
  }
  function resolveSelection(view, doc3, parsedSel) {
    if (Math.max(parsedSel.anchor, parsedSel.head) > doc3.content.size)
      return null;
    return selectionBetween(view, doc3.resolve(parsedSel.anchor), doc3.resolve(parsedSel.head));
  }
  function isMarkChange(cur, prev) {
    let curMarks = cur.firstChild.marks, prevMarks = prev.firstChild.marks;
    let added = curMarks, removed = prevMarks, type, mark, update;
    for (let i = 0; i < prevMarks.length; i++)
      added = prevMarks[i].removeFromSet(added);
    for (let i = 0; i < curMarks.length; i++)
      removed = curMarks[i].removeFromSet(removed);
    if (added.length == 1 && removed.length == 0) {
      mark = added[0];
      type = "add";
      update = (node) => node.mark(mark.addToSet(node.marks));
    } else if (added.length == 0 && removed.length == 1) {
      mark = removed[0];
      type = "remove";
      update = (node) => node.mark(mark.removeFromSet(node.marks));
    } else {
      return null;
    }
    let updated = [];
    for (let i = 0; i < prev.childCount; i++)
      updated.push(update(prev.child(i)));
    if (Fragment.from(updated).eq(cur))
      return { mark, type };
  }
  function looksLikeBlockJoin(old, start, end, $newStart, $newEnd) {
    if (
      // The content must have shrunk
      end - start <= $newEnd.pos - $newStart.pos || // newEnd must point directly at or after the end of the block that newStart points into
      skipClosingAndOpening($newStart, true, false) < $newEnd.pos
    )
      return false;
    let $start = old.resolve(start);
    if (!$newStart.parent.inlineContent) {
      let after = $start.nodeAfter;
      return after != null && end == start + after.nodeSize;
    }
    if ($start.parentOffset < $start.parent.content.size || !$start.parent.isTextblock)
      return false;
    let $next = old.resolve(skipClosingAndOpening($start, true, true));
    if (!$next.parent.isTextblock || $next.pos > end || skipClosingAndOpening($next, true, false) < end)
      return false;
    return $newStart.parent.content.cut($newStart.parentOffset).eq($next.parent.content);
  }
  function looksLikeEnter(content, from2, to) {
    let newTextlines = 0, newLeaves = 0;
    content.nodesBetween(from2, to, (node, pos) => {
      if (node.isTextblock && pos >= from2 && pos < to)
        newTextlines++;
      else if (node.isText ? /\S/.test(node.text.slice(Math.max(0, from2 - pos), Math.min(node.nodeSize, to - pos))) : node.isLeaf)
        newLeaves++;
    });
    return newLeaves == 0 && newTextlines == 1;
  }
  function skipClosingAndOpening($pos, fromEnd, mayOpen) {
    let depth = $pos.depth, end = fromEnd ? $pos.end() : $pos.pos;
    while (depth > 0 && (fromEnd || $pos.indexAfter(depth) == $pos.node(depth).childCount)) {
      depth--;
      end++;
      fromEnd = false;
    }
    if (mayOpen) {
      let next = $pos.node(depth).maybeChild($pos.indexAfter(depth));
      while (next && !next.isLeaf) {
        next = next.firstChild;
        end++;
      }
    }
    return end;
  }
  function findDiff(a, b, pos, preferredPos, preferredSide) {
    let start = a.findDiffStart(b, pos), lenA = pos + a.size, lenB = pos + b.size;
    if (start == null)
      return null;
    let { a: endA, b: endB } = a.findDiffEnd(b, lenA, lenB);
    if (preferredSide == "end") {
      let adjust = Math.max(0, start - Math.min(endA, endB));
      preferredPos -= endA + adjust - start;
    }
    if (endA < start && lenA < lenB) {
      let move = preferredPos <= start && preferredPos >= endA ? start - preferredPos : 0;
      start -= move;
      endB = start + (endB - endA);
      endA = start;
    } else if (endB < start) {
      let move = preferredPos <= start && preferredPos >= endB ? start - preferredPos : 0;
      start -= move;
      endA = start + (endA - endB);
      endB = start;
    }
    return { start, endA, endB };
  }
  var observeOptions = {
    childList: true,
    characterData: true,
    characterDataOldValue: true,
    attributes: true,
    attributeOldValue: true,
    subtree: true
  };
  var DOMObserver = class {
    constructor(view) {
      this.view = view;
      this.queue = [];
      this.flushingSoon = -1;
      this.suppressingSelectionUpdates = false;
      this.lastChangedTextNode = null;
      this.started = false;
      this.observer = new window.MutationObserver((mutations) => {
        for (let i = 0; i < mutations.length; i++)
          this.queue.push(mutations[i]);
        if (safari && view.composing && mutations.some((m) => m.type == "childList" && m.target.nodeName == "TR")) {
          view.input.badSafariComposition = true;
          this.flushSoon();
        } else {
          this.flush();
        }
      });
    }
    flushSoon() {
      if (this.flushingSoon < 0)
        this.flushingSoon = window.setTimeout(() => {
          this.flushingSoon = -1;
          this.flush();
        }, 20);
    }
    forceFlush(always = false) {
      if (this.flushingSoon > -1) {
        window.clearTimeout(this.flushingSoon);
        this.flushingSoon = -1;
        this.flush(true);
      } else if (always) {
        this.flush(true);
      }
    }
    start() {
      this.observer.takeRecords();
      this.observer.observe(this.view.dom, observeOptions);
      this.started = true;
    }
    stop() {
      let take = this.observer.takeRecords();
      if (take.length) {
        for (let i = 0; i < take.length; i++)
          this.queue.push(take[i]);
        window.setTimeout(() => this.flush(), 20);
      }
      this.observer.disconnect();
      this.started = false;
    }
    stopped(f) {
      if (!this.started)
        return f();
      this.stop();
      try {
        return f();
      } finally {
        this.start();
      }
    }
    ignoreSelectionChange(sel) {
      if (!sel.focusNode)
        return true;
      let ancestors = /* @__PURE__ */ new Set(), container;
      for (let scan = sel.focusNode; scan; scan = parentNode(scan))
        ancestors.add(scan);
      for (let scan = sel.anchorNode; scan; scan = parentNode(scan))
        if (ancestors.has(scan)) {
          container = scan;
          break;
        }
      let desc = container && this.view.docView.nearestDesc(container);
      if (desc && desc.ignoreMutation({
        type: "selection",
        target: isText(container) ? container.parentNode : container
      })) {
        this.view.domSel.ignore(sel);
        return true;
      }
    }
    pendingRecords() {
      for (let mut of this.observer.takeRecords())
        this.queue.push(mut);
      return this.queue;
    }
    flush(readSel = true) {
      let { view } = this;
      if (!view.docView || this.flushingSoon > -1)
        return;
      let mutations = this.pendingRecords();
      if (mutations.length)
        this.queue = [];
      if (readSel)
        view.domSel.read();
      let selChange = !view.domSel.suppress && !view.domSel.synced && !!hasFocusAndSelection(view) && !this.ignoreSelectionChange(view.domSel.range);
      let from2 = -1, to = -1, typeOver = false, added = [];
      if (view.editable) {
        for (let i = 0; i < mutations.length; i++) {
          let result = this.registerMutation(mutations[i], added);
          if (result) {
            from2 = from2 < 0 ? result.from : Math.min(result.from, from2);
            to = to < 0 ? result.to : Math.max(result.to, to);
            if (result.typeOver)
              typeOver = true;
          }
        }
      }
      if (added.some((n) => n.nodeName == "BR") && (view.input.lastKeyCode == 8 || view.input.lastKeyCode == 46 || chrome && (view.composing || view.input.compositionEndedAt > Date.now() - 50) && mutations.some((m) => m.type == "childList" && m.removedNodes.length))) {
        for (let node of added)
          if (node.nodeName == "BR" && node.parentNode) {
            let after = node.nextSibling;
            while (after && isElt(after)) {
              if (after.contentEditable == "false") {
                node.parentNode.removeChild(node);
                break;
              }
              after = after.firstChild;
            }
          }
      } else if (gecko && added.length) {
        let brs = added.filter((n) => n.nodeName == "BR");
        if (brs.length == 2) {
          let [a, b] = brs;
          if (a.parentNode && a.parentNode.parentNode == b.parentNode)
            b.remove();
          else
            a.remove();
        } else {
          let { focusNode } = view.domSel.range;
          for (let br of brs) {
            let parent = br.parentNode;
            if (parent && parent.nodeName == "LI" && (!focusNode || blockParent(view, focusNode) != parent))
              br.remove();
          }
        }
      }
      let newSel = null;
      if (from2 < 0 && selChange && view.domSel.active && view.input.lastFocus > Date.now() - 200 && view.input.lastTouch < Date.now() - 300 && selectionCollapsed(view.domSel.range) && (newSel = selectionFromDOM(view, view.domSel.range)) && newSel.eq(Selection.near(view.state.doc.resolve(0), 1))) {
        view.input.lastFocus = 0;
        view.domSel.sync();
        view.scrollToSelection();
      } else if (from2 > -1 || selChange) {
        if (from2 > -1)
          checkCSS(view);
        if (view.input.badSafariComposition) {
          view.input.badSafariComposition = false;
          fixUpBadSafariComposition(view, added);
        }
        readDOMChange(this.view, from2, to, selChange, typeOver, added);
        if (view.docView && view.docView.damage)
          view.updateState(view.state);
        else if (selChange)
          view.domSel.sync();
      }
    }
    registerMutation(mut, added) {
      var _a;
      if (added.indexOf(mut.target) > -1)
        return null;
      let desc;
      for (let scan = mut.target; scan; scan = scan.parentNode) {
        if (desc = this.view.docView.getDesc(scan))
          break;
      }
      if (mut.type == "attributes" && (desc == this.view.docView || mut.attributeName == "contenteditable" || // Firefox sometimes fires spurious events for null/empty styles
      mut.attributeName == "style" && !mut.oldValue && !mut.target.getAttribute("style")))
        return null;
      if (!desc || desc.ignoreMutation(mut))
        return null;
      if (mut.type == "childList") {
        for (let i = 0; i < mut.addedNodes.length; i++) {
          let node = mut.addedNodes[i];
          added.push(node);
          if (isText(node))
            this.lastChangedTextNode = node;
        }
        if (desc.contentDOM && desc.contentDOM != desc.dom && !desc.contentDOM.contains(mut.target)) {
          desc.markDamage(
            4
            /* Damage.Structure */
          );
          return { from: desc.posBefore, to: desc.posAfter };
        }
        let prev = mut.previousSibling, next = mut.nextSibling;
        let fromOffset = prev && prev.parentNode == mut.target ? domIndex(prev) + 1 : 0;
        let from2 = desc.localPosFromDOM(mut.target, fromOffset, -1);
        let toOffset = next && next.parentNode == mut.target ? domIndex(next) : mut.target.childNodes.length;
        let to = desc.localPosFromDOM(mut.target, toOffset, 1);
        desc.markDamage(
          ((_a = desc.contentDOM) === null || _a === void 0 ? void 0 : _a.contains(mut.target)) ? 2 : 4
          /* Damage.Structure */
        );
        return { from: from2, to };
      } else if (mut.type == "attributes") {
        desc.markDamage(
          4
          /* Damage.Structure */
        );
        return { from: desc.posAtStart - desc.border, to: desc.posAtEnd + desc.border };
      } else {
        this.lastChangedTextNode = mut.target;
        desc.markDamage(
          desc instanceof TextViewDesc && mut.target == desc.nodeDOM ? 8 : 4
          /* Damage.Structure */
        );
        return {
          from: desc.posAtStart,
          to: desc.posAtEnd,
          // An event was generated for a text change that didn't change
          // any text. Mark the dom change to fall back to assuming the
          // selection was typed over with an identical value if it can't
          // find another change.
          typeOver: mut.target.nodeValue == mut.oldValue
        };
      }
    }
  };
  var cssChecked = /* @__PURE__ */ new WeakMap();
  var cssCheckWarned = false;
  function checkCSS(view) {
    if (cssChecked.has(view))
      return;
    cssChecked.set(view, null);
    if (["normal", "nowrap", "pre-line"].indexOf(getComputedStyle(view.dom).whiteSpace) !== -1) {
      view.requiresGeckoHackNode = gecko;
      if (cssCheckWarned)
        return;
      console["warn"]("ProseMirror expects the CSS white-space property to be set, preferably to 'pre-wrap'. It is recommended to load style/prosemirror.css from the prosemirror-view package.");
      cssCheckWarned = true;
    }
  }
  function blockParent(view, node) {
    for (let p = node.parentNode; p && p != view.dom; p = p.parentNode) {
      let desc = view.docView.nearestDesc(p, true);
      if (desc && desc.node.isBlock)
        return p;
    }
    return null;
  }
  function fixUpBadSafariComposition(view, addedNodes) {
    var _a;
    let { focusNode, focusOffset } = view.domSel.range;
    for (let node of addedNodes) {
      if (((_a = node.parentNode) === null || _a === void 0 ? void 0 : _a.nodeName) == "TR") {
        let nextCell = node.nextSibling;
        while (nextCell && (nextCell.nodeName != "TD" && nextCell.nodeName != "TH"))
          nextCell = nextCell.nextSibling;
        if (nextCell) {
          let parent = nextCell;
          for (; ; ) {
            let first = parent.firstChild;
            if (!first || !isElt(first) || first.contentEditable == "false" || /^(BR|IMG)$/.test(first.nodeName))
              break;
            parent = first;
          }
          parent.insertBefore(node, parent.firstChild);
          if (focusNode == node)
            view.domSelection().collapse(node, focusOffset);
        } else {
          node.parentNode.removeChild(node);
        }
      }
    }
  }
  var EditorView = class {
    /**
    Create a view. `place` may be a DOM node that the editor should
    be appended to, a function that will place it into the document,
    or an object whose `mount` property holds the node to use as the
    document container. If it is `null`, the editor will not be
    added to the document.
    */
    constructor(place, props) {
      this._root = null;
      this.focused = false;
      this.trackWrites = null;
      this.mounted = false;
      this.markCursor = null;
      this.cursorWrapper = null;
      this.lastSelectedViewDesc = void 0;
      this.input = new InputState();
      this.prevDirectPlugins = [];
      this.pluginViews = [];
      this.requiresGeckoHackNode = false;
      this.dragging = null;
      this._props = props;
      this.state = props.state;
      this.directPlugins = props.plugins || [];
      this.directPlugins.forEach(checkStateComponent);
      this.dispatch = this.dispatch.bind(this);
      this.dom = place && place.mount || document.createElement("div");
      if (place) {
        if (place.appendChild)
          place.appendChild(this.dom);
        else if (typeof place == "function")
          place(this.dom);
        else if (place.mount)
          this.mounted = true;
      }
      this.editable = getEditable(this);
      updateCursorWrapper(this);
      this.nodeViews = buildNodeViews(this);
      this.docView = docViewDesc(this.state.doc, computeDocDeco(this), viewDecorations(this), this.dom, this);
      this.domObserver = new DOMObserver(this);
      this.domSel = new DOMSelState(this);
      this.domObserver.start();
      this.domSel.read();
      initInput(this);
      this.updatePluginViews();
    }
    /**
    Holds `true` when a
    [composition](https://w3c.github.io/uievents/#events-compositionevents)
    is active.
    */
    get composing() {
      return this.input.composing;
    }
    /**
    The view's current [props](https://prosemirror.net/docs/ref/#view.EditorProps).
    */
    get props() {
      if (this._props.state != this.state) {
        let prev = this._props;
        this._props = {};
        for (let name in prev)
          this._props[name] = prev[name];
        this._props.state = this.state;
      }
      return this._props;
    }
    /**
    Update the view's props. Will immediately cause an update to
    the DOM.
    */
    update(props) {
      if (props.handleDOMEvents != this._props.handleDOMEvents)
        ensureListeners(this);
      let prevProps = this._props;
      this._props = props;
      if (props.plugins) {
        props.plugins.forEach(checkStateComponent);
        this.directPlugins = props.plugins;
      }
      this.updateStateInner(props.state, prevProps);
    }
    /**
    Update the view by updating existing props object with the object
    given as argument. Equivalent to `view.update(Object.assign({},
    view.props, props))`.
    */
    setProps(props) {
      let updated = {};
      for (let name in this._props)
        updated[name] = this._props[name];
      updated.state = this.state;
      for (let name in props)
        updated[name] = props[name];
      this.update(updated);
    }
    /**
    Update the editor's `state` prop, without touching any of the
    other props.
    */
    updateState(state) {
      this.updateStateInner(state, this._props);
    }
    updateStateInner(state, prevProps) {
      var _a;
      let prev = this.state, redraw = false, updateSel = false;
      if (state.storedMarks && this.composing) {
        clearComposition(this);
        updateSel = true;
      }
      this.state = state;
      let pluginsChanged = prev.plugins != state.plugins || this._props.plugins != prevProps.plugins;
      if (pluginsChanged || this._props.plugins != prevProps.plugins || this._props.nodeViews != prevProps.nodeViews) {
        let nodeViews = buildNodeViews(this);
        if (changedNodeViews(nodeViews, this.nodeViews)) {
          this.nodeViews = nodeViews;
          redraw = true;
        }
      }
      if (pluginsChanged || prevProps.handleDOMEvents != this._props.handleDOMEvents) {
        ensureListeners(this);
      }
      this.editable = getEditable(this);
      updateCursorWrapper(this);
      let innerDeco = viewDecorations(this), outerDeco = computeDocDeco(this);
      let scroll = prev.plugins != state.plugins && !prev.doc.eq(state.doc) ? "reset" : state.scrollToSelection > prev.scrollToSelection ? "to selection" : "preserve";
      let updateDoc = redraw || !this.docView.matchesNode(state.doc, outerDeco, innerDeco);
      if (updateDoc || !state.selection.eq(prev.selection))
        updateSel = true;
      let oldScrollPos = scroll == "preserve" && updateSel && this.dom.style.overflowAnchor == null && storeScrollPos(this);
      if (updateSel)
        this.domObserver.stopped(() => {
          let forceSelUpdate = updateDoc && chrome && !this.composing && !prev.selection.empty && !state.selection.empty && selectionContextChanged(prev.selection, state.selection);
          if (updateDoc) {
            let chromeKludge = chrome ? this.trackWrites = this.domSel.range.focusNode : null;
            if (this.composing)
              this.input.compositionNode = findCompositionNode(this);
            if (redraw || !this.docView.update(state.doc, outerDeco, innerDeco, this, -1)) {
              let prevOuter = this.docView.outerDeco;
              this.docView.destroy();
              this.docView = docViewDesc(state.doc, outerDeco, innerDeco, this.dom, this, prevOuter);
            }
            if (chromeKludge && (!this.trackWrites || !this.dom.contains(this.trackWrites)))
              forceSelUpdate = true;
          }
          this.domSel.sync(forceSelUpdate);
        });
      this.updatePluginViews(prev);
      if (((_a = this.dragging) === null || _a === void 0 ? void 0 : _a.node) && !prev.doc.eq(state.doc))
        this.updateDraggedNode(this.dragging, prev);
      if (scroll == "reset") {
        this.dom.scrollTop = 0;
      } else if (scroll == "to selection") {
        this.scrollToSelection();
      } else if (oldScrollPos) {
        resetScrollPos(oldScrollPos);
      }
    }
    /**
    @internal
    */
    scrollToSelection() {
      let startDOM = this.domSel.range.focusNode;
      if (!startDOM || !this.domSel.active) ;
      else if (this.someProp("handleScrollToSelection", (f) => f(this))) ;
      else if (this.state.selection instanceof NodeSelection) {
        let target = this.docView.domAfterPos(this.state.selection.from);
        if (isElt(target))
          scrollRectIntoView(this, target.getBoundingClientRect(), startDOM);
      } else {
        scrollRectIntoView(this, this.coordsAtPos(this.state.selection.head, 1), startDOM);
      }
    }
    destroyPluginViews() {
      let view;
      while (view = this.pluginViews.pop())
        if (view.destroy)
          view.destroy();
    }
    updatePluginViews(prevState) {
      if (!prevState || prevState.plugins != this.state.plugins || this.directPlugins != this.prevDirectPlugins) {
        this.prevDirectPlugins = this.directPlugins;
        this.destroyPluginViews();
        for (let i = 0; i < this.directPlugins.length; i++) {
          let plugin = this.directPlugins[i];
          if (plugin.spec.view)
            this.pluginViews.push(plugin.spec.view(this));
        }
        for (let i = 0; i < this.state.plugins.length; i++) {
          let plugin = this.state.plugins[i];
          if (plugin.spec.view)
            this.pluginViews.push(plugin.spec.view(this));
        }
      } else {
        for (let i = 0; i < this.pluginViews.length; i++) {
          let pluginView = this.pluginViews[i];
          if (pluginView.update)
            pluginView.update(this, prevState);
        }
      }
    }
    updateDraggedNode(dragging, prev) {
      let sel = dragging.node, found2 = -1;
      if (sel.from < this.state.doc.content.size && this.state.doc.nodeAt(sel.from) == sel.node) {
        found2 = sel.from;
      } else {
        let movedPos = sel.from + (this.state.doc.content.size - prev.doc.content.size);
        let moved = movedPos > 0 && movedPos < this.state.doc.content.size && this.state.doc.nodeAt(movedPos);
        if (moved == sel.node)
          found2 = movedPos;
      }
      this.dragging = new Dragging(dragging.slice, dragging.move, found2 < 0 ? void 0 : NodeSelection.create(this.state.doc, found2));
    }
    someProp(propName, f) {
      let prop = this._props && this._props[propName], value;
      if (prop != null && (value = f ? f(prop) : prop))
        return value;
      for (let i = 0; i < this.directPlugins.length; i++) {
        let prop2 = this.directPlugins[i].props[propName];
        if (prop2 != null && (value = f ? f(prop2) : prop2))
          return value;
      }
      let plugins = this.state.plugins;
      if (plugins)
        for (let i = 0; i < plugins.length; i++) {
          let prop2 = plugins[i].props[propName];
          if (prop2 != null && (value = f ? f(prop2) : prop2))
            return value;
        }
    }
    /**
    Query whether the view has focus.
    */
    hasFocus() {
      return this.root.activeElement == this.dom;
    }
    /**
    Focus the editor.
    */
    focus() {
      if (this.editable)
        focusPreventScroll(this.dom);
      this.domSel.sync();
    }
    /**
    Get the document root in which the editor exists. This will
    usually be the top-level `document`, but might be a [shadow
    DOM](https://developer.mozilla.org/en-US/docs/Web/Web_Components/Shadow_DOM)
    root if the editor is inside one.
    */
    get root() {
      let connected = this.dom.isConnected !== false;
      if (!connected)
        this._root = null;
      let cached = this._root;
      if (cached == null && connected)
        for (let search = this.dom.parentNode; search; search = search.parentNode) {
          if (search.nodeType == 9 || search.nodeType == 11 && search.host) {
            if (!search.getSelection)
              Object.getPrototypeOf(search).getSelection = () => search.ownerDocument.getSelection();
            return this._root = search;
          }
        }
      return cached || document;
    }
    /**
    When an existing editor view is moved to a new document or
    shadow tree, call this to make it recompute its root.
    */
    updateRoot() {
      this._root = null;
    }
    /**
    Given a pair of viewport coordinates, return the document
    position that corresponds to them. May return null if the given
    coordinates aren't inside of the editor. When an object is
    returned, its `pos` property is the position nearest to the
    coordinates, and its `inside` property holds the position of the
    inner node that the position falls inside of, or -1 if it is at
    the top level, not in any node.
    */
    posAtCoords(coords) {
      return posAtCoords(this, coords);
    }
    /**
    Returns the viewport rectangle at a given document position.
    `left` and `right` will be the same number, as this returns a
    flat cursor-ish rectangle. If the position is between two things
    that aren't directly adjacent, `side` determines which element
    is used. When < 0, the element before the position is used,
    otherwise the element after.
    */
    coordsAtPos(pos, side = 1) {
      return coordsAtPos(this, pos, side);
    }
    /**
    Find the DOM position that corresponds to the given document
    position. When `side` is negative, find the position as close as
    possible to the content before the position. When positive,
    prefer positions close to the content after the position. When
    zero, prefer as shallow a position as possible.
    
    Note that you should **not** mutate the editor's internal DOM,
    only inspect it (and even that is usually not necessary).
    */
    domAtPos(pos, side = 0) {
      return this.docView.domFromPos(pos, side);
    }
    /**
    Find the DOM node that represents the document node after the
    given position. May return `null` when the position doesn't point
    in front of a node or if the node is inside an opaque node view.
    
    This is intended to be able to call things like
    `getBoundingClientRect` on that DOM node. Do **not** mutate the
    editor DOM directly, or add styling this way, since that will be
    immediately overriden by the editor as it redraws the node.
    */
    nodeDOM(pos) {
      let desc = this.docView.descAt(pos);
      return desc ? desc.nodeDOM : null;
    }
    /**
    Find the document position that corresponds to a given DOM
    position. (Whenever possible, it is preferable to inspect the
    document structure directly, rather than poking around in the
    DOM, but sometimes—for example when interpreting an event
    target—you don't have a choice.)
    
    The `bias` parameter can be used to influence which side of a DOM
    node to use when the position is inside a leaf node.
    */
    posAtDOM(node, offset, bias = -1) {
      let pos = this.docView.posFromDOM(node, offset, bias);
      if (pos == null)
        throw new RangeError("DOM position not inside the editor");
      return pos;
    }
    /**
    Find out whether the selection is at the end of a textblock when
    moving in a given direction. When, for example, given `"left"`,
    it will return true if moving left from the current cursor
    position would leave that position's parent textblock. Will apply
    to the view's current state by default, but it is possible to
    pass a different state.
    */
    endOfTextblock(dir, state) {
      return endOfTextblock(this, state || this.state, dir);
    }
    /**
    Run the editor's paste logic with the given HTML string. The
    `event`, if given, will be passed to the
    [`handlePaste`](https://prosemirror.net/docs/ref/#view.EditorProps.handlePaste) hook.
    */
    pasteHTML(html, event) {
      return doPaste(this, "", html, false, event || new ClipboardEvent("paste"));
    }
    /**
    Run the editor's paste logic with the given plain-text input.
    */
    pasteText(text, event) {
      return doPaste(this, text, null, true, event || new ClipboardEvent("paste"));
    }
    /**
    Serialize the given slice as it would be if it was copied from
    this editor. Returns a DOM element that contains a
    representation of the slice as its children, a textual
    representation, and the transformed slice (which can be
    different from the given input due to hooks like
    [`transformCopied`](https://prosemirror.net/docs/ref/#view.EditorProps.transformCopied)).
    */
    serializeForClipboard(slice2) {
      return serializeForClipboard(this, slice2);
    }
    /**
    Removes the editor from the DOM and destroys all [node
    views](https://prosemirror.net/docs/ref/#view.NodeView).
    */
    destroy() {
      if (!this.docView)
        return;
      destroyInput(this);
      this.domSel.destroy();
      this.destroyPluginViews();
      if (this.mounted) {
        this.docView.update(this.state.doc, [], viewDecorations(this), this, -1);
        this.dom.textContent = "";
      } else if (this.dom.parentNode) {
        this.dom.parentNode.removeChild(this.dom);
      }
      this.docView.destroy();
      this.docView = null;
      clearReusedRange();
    }
    /**
    This is true when the view has been
    [destroyed](https://prosemirror.net/docs/ref/#view.EditorView.destroy) (and thus should not be
    used anymore).
    */
    get isDestroyed() {
      return this.docView == null;
    }
    /**
    Used for testing.
    */
    dispatchEvent(event) {
      return dispatchEvent(this, event);
    }
    /**
    @internal
    */
    domSelection() {
      return this.root.getSelection();
    }
  };
  EditorView.prototype.dispatch = function(tr) {
    let dispatchTransaction = this._props.dispatchTransaction;
    if (dispatchTransaction)
      dispatchTransaction.call(this, tr);
    else
      this.updateState(this.state.apply(tr));
  };
  function computeDocDeco(view) {
    let attrs = /* @__PURE__ */ Object.create(null);
    attrs.class = "ProseMirror";
    attrs.contenteditable = String(view.editable);
    view.someProp("attributes", (value) => {
      if (typeof value == "function")
        value = value(view.state);
      if (value)
        for (let attr in value) {
          if (attr == "class")
            attrs.class += " " + value[attr];
          else if (attr == "style")
            attrs.style = (attrs.style ? attrs.style + ";" : "") + value[attr];
          else if (!attrs[attr] && attr != "contenteditable" && attr != "nodeName")
            attrs[attr] = String(value[attr]);
        }
    });
    if (!attrs.translate)
      attrs.translate = "no";
    return [Decoration.node(0, view.state.doc.content.size, attrs)];
  }
  function updateCursorWrapper(view) {
    if (view.markCursor) {
      let dom = document.createElement("wbr");
      dom.className = "ProseMirror-separator";
      dom.setAttribute("mark-placeholder", "true");
      dom.setAttribute("alt", "");
      view.cursorWrapper = { dom, deco: Decoration.widget(view.state.selection.from, dom, { raw: true, marks: view.markCursor }) };
    } else {
      view.cursorWrapper = null;
    }
  }
  function getEditable(view) {
    return !view.someProp("editable", (value) => value(view.state) === false);
  }
  function selectionContextChanged(sel1, sel2) {
    let depth = Math.min(sel1.$anchor.sharedDepth(sel1.head), sel2.$anchor.sharedDepth(sel2.head));
    return sel1.$anchor.start(depth) != sel2.$anchor.start(depth);
  }
  function buildNodeViews(view) {
    let result = /* @__PURE__ */ Object.create(null);
    function add(obj) {
      for (let prop in obj)
        if (!Object.prototype.hasOwnProperty.call(result, prop))
          result[prop] = obj[prop];
    }
    view.someProp("nodeViews", add);
    view.someProp("markViews", add);
    return result;
  }
  function changedNodeViews(a, b) {
    let nA = 0, nB = 0;
    for (let prop in a) {
      if (a[prop] != b[prop])
        return true;
      nA++;
    }
    for (let _ in b)
      nB++;
    return nA != nB;
  }
  function checkStateComponent(plugin) {
    if (plugin.spec.state || plugin.spec.filterTransaction || plugin.spec.appendTransaction)
      throw new RangeError("Plugins passed directly to the view must not have a state component");
  }

  // node_modules/rope-sequence/dist/index.js
  var GOOD_LEAF_SIZE = 200;
  var RopeSequence = function RopeSequence2() {
  };
  RopeSequence.prototype.append = function append(other) {
    if (!other.length) {
      return this;
    }
    other = RopeSequence.from(other);
    return !this.length && other || other.length < GOOD_LEAF_SIZE && this.leafAppend(other) || this.length < GOOD_LEAF_SIZE && other.leafPrepend(this) || this.appendInner(other);
  };
  RopeSequence.prototype.prepend = function prepend(other) {
    if (!other.length) {
      return this;
    }
    return RopeSequence.from(other).append(this);
  };
  RopeSequence.prototype.appendInner = function appendInner(other) {
    return new Append(this, other);
  };
  RopeSequence.prototype.slice = function slice(from2, to) {
    if (from2 === void 0) from2 = 0;
    if (to === void 0) to = this.length;
    if (from2 >= to) {
      return RopeSequence.empty;
    }
    return this.sliceInner(Math.max(0, from2), Math.min(this.length, to));
  };
  RopeSequence.prototype.get = function get(i) {
    if (i < 0 || i >= this.length) {
      return void 0;
    }
    return this.getInner(i);
  };
  RopeSequence.prototype.forEach = function forEach(f, from2, to) {
    if (from2 === void 0) from2 = 0;
    if (to === void 0) to = this.length;
    if (from2 <= to) {
      this.forEachInner(f, from2, to, 0);
    } else {
      this.forEachInvertedInner(f, from2, to, 0);
    }
  };
  RopeSequence.prototype.map = function map(f, from2, to) {
    if (from2 === void 0) from2 = 0;
    if (to === void 0) to = this.length;
    var result = [];
    this.forEach(function(elt, i) {
      return result.push(f(elt, i));
    }, from2, to);
    return result;
  };
  RopeSequence.from = function from(values) {
    if (values instanceof RopeSequence) {
      return values;
    }
    return values && values.length ? new Leaf(values) : RopeSequence.empty;
  };
  var Leaf = /* @__PURE__ */ function(RopeSequence3) {
    function Leaf2(values) {
      RopeSequence3.call(this);
      this.values = values;
    }
    if (RopeSequence3) Leaf2.__proto__ = RopeSequence3;
    Leaf2.prototype = Object.create(RopeSequence3 && RopeSequence3.prototype);
    Leaf2.prototype.constructor = Leaf2;
    var prototypeAccessors = { length: { configurable: true }, depth: { configurable: true } };
    Leaf2.prototype.flatten = function flatten() {
      return this.values;
    };
    Leaf2.prototype.sliceInner = function sliceInner(from2, to) {
      if (from2 == 0 && to == this.length) {
        return this;
      }
      return new Leaf2(this.values.slice(from2, to));
    };
    Leaf2.prototype.getInner = function getInner(i) {
      return this.values[i];
    };
    Leaf2.prototype.forEachInner = function forEachInner(f, from2, to, start) {
      for (var i = from2; i < to; i++) {
        if (f(this.values[i], start + i) === false) {
          return false;
        }
      }
    };
    Leaf2.prototype.forEachInvertedInner = function forEachInvertedInner(f, from2, to, start) {
      for (var i = from2 - 1; i >= to; i--) {
        if (f(this.values[i], start + i) === false) {
          return false;
        }
      }
    };
    Leaf2.prototype.leafAppend = function leafAppend(other) {
      if (this.length + other.length <= GOOD_LEAF_SIZE) {
        return new Leaf2(this.values.concat(other.flatten()));
      }
    };
    Leaf2.prototype.leafPrepend = function leafPrepend(other) {
      if (this.length + other.length <= GOOD_LEAF_SIZE) {
        return new Leaf2(other.flatten().concat(this.values));
      }
    };
    prototypeAccessors.length.get = function() {
      return this.values.length;
    };
    prototypeAccessors.depth.get = function() {
      return 0;
    };
    Object.defineProperties(Leaf2.prototype, prototypeAccessors);
    return Leaf2;
  }(RopeSequence);
  RopeSequence.empty = new Leaf([]);
  var Append = /* @__PURE__ */ function(RopeSequence3) {
    function Append2(left, right) {
      RopeSequence3.call(this);
      this.left = left;
      this.right = right;
      this.length = left.length + right.length;
      this.depth = Math.max(left.depth, right.depth) + 1;
    }
    if (RopeSequence3) Append2.__proto__ = RopeSequence3;
    Append2.prototype = Object.create(RopeSequence3 && RopeSequence3.prototype);
    Append2.prototype.constructor = Append2;
    Append2.prototype.flatten = function flatten() {
      return this.left.flatten().concat(this.right.flatten());
    };
    Append2.prototype.getInner = function getInner(i) {
      return i < this.left.length ? this.left.get(i) : this.right.get(i - this.left.length);
    };
    Append2.prototype.forEachInner = function forEachInner(f, from2, to, start) {
      var leftLen = this.left.length;
      if (from2 < leftLen && this.left.forEachInner(f, from2, Math.min(to, leftLen), start) === false) {
        return false;
      }
      if (to > leftLen && this.right.forEachInner(f, Math.max(from2 - leftLen, 0), Math.min(this.length, to) - leftLen, start + leftLen) === false) {
        return false;
      }
    };
    Append2.prototype.forEachInvertedInner = function forEachInvertedInner(f, from2, to, start) {
      var leftLen = this.left.length;
      if (from2 > leftLen && this.right.forEachInvertedInner(f, from2 - leftLen, Math.max(to, leftLen) - leftLen, start + leftLen) === false) {
        return false;
      }
      if (to < leftLen && this.left.forEachInvertedInner(f, Math.min(from2, leftLen), to, start) === false) {
        return false;
      }
    };
    Append2.prototype.sliceInner = function sliceInner(from2, to) {
      if (from2 == 0 && to == this.length) {
        return this;
      }
      var leftLen = this.left.length;
      if (to <= leftLen) {
        return this.left.slice(from2, to);
      }
      if (from2 >= leftLen) {
        return this.right.slice(from2 - leftLen, to - leftLen);
      }
      return this.left.slice(from2, leftLen).append(this.right.slice(0, to - leftLen));
    };
    Append2.prototype.leafAppend = function leafAppend(other) {
      var inner = this.right.leafAppend(other);
      if (inner) {
        return new Append2(this.left, inner);
      }
    };
    Append2.prototype.leafPrepend = function leafPrepend(other) {
      var inner = this.left.leafPrepend(other);
      if (inner) {
        return new Append2(inner, this.right);
      }
    };
    Append2.prototype.appendInner = function appendInner2(other) {
      if (this.left.depth >= Math.max(this.right.depth, other.depth) + 1) {
        return new Append2(this.left, new Append2(this.right, other));
      }
      return new Append2(this, other);
    };
    return Append2;
  }(RopeSequence);
  var dist_default2 = RopeSequence;

  // node_modules/prosemirror-history/dist/index.js
  var max_empty_items = 500;
  var Branch = class _Branch {
    constructor(items, eventCount) {
      this.items = items;
      this.eventCount = eventCount;
    }
    // Pop the latest event off the branch's history and apply it
    // to a document transform.
    popEvent(state, preserveItems) {
      if (this.eventCount == 0)
        return null;
      let end = this.items.length;
      for (; ; end--) {
        let next = this.items.get(end - 1);
        if (next.selection) {
          --end;
          break;
        }
      }
      let remap, mapFrom;
      if (preserveItems) {
        remap = this.remapping(end, this.items.length);
        mapFrom = remap.maps.length;
      }
      let transform = state.tr;
      let selection, remaining;
      let addAfter = [], addBefore = [];
      this.items.forEach((item, i) => {
        if (!item.step) {
          if (!remap) {
            remap = this.remapping(end, i + 1);
            mapFrom = remap.maps.length;
          }
          mapFrom--;
          addBefore.push(item);
          return;
        }
        if (remap) {
          addBefore.push(new Item(item.map));
          let step = item.step.map(remap.slice(mapFrom)), map2;
          if (step && transform.maybeStep(step).doc) {
            map2 = transform.mapping.maps[transform.mapping.maps.length - 1];
            addAfter.push(new Item(map2, void 0, void 0, addAfter.length + addBefore.length));
          }
          mapFrom--;
          if (map2)
            remap.appendMap(map2, mapFrom);
        } else {
          transform.maybeStep(item.step);
        }
        if (item.selection) {
          selection = remap ? item.selection.map(remap.slice(mapFrom)) : item.selection;
          remaining = new _Branch(this.items.slice(0, end).append(addBefore.reverse().concat(addAfter)), this.eventCount - 1);
          return false;
        }
      }, this.items.length, 0);
      return { remaining, transform, selection };
    }
    // Create a new branch with the given transform added.
    addTransform(transform, selection, histOptions, preserveItems) {
      let newItems = [], eventCount = this.eventCount;
      let oldItems = this.items, lastItem = !preserveItems && oldItems.length ? oldItems.get(oldItems.length - 1) : null;
      for (let i = 0; i < transform.steps.length; i++) {
        let step = transform.steps[i].invert(transform.docs[i]);
        let item = new Item(transform.mapping.maps[i], step, selection), merged;
        if (merged = lastItem && lastItem.merge(item)) {
          item = merged;
          if (i)
            newItems.pop();
          else
            oldItems = oldItems.slice(0, oldItems.length - 1);
        }
        newItems.push(item);
        if (selection) {
          eventCount++;
          selection = void 0;
        }
        if (!preserveItems)
          lastItem = item;
      }
      let overflow = eventCount - histOptions.depth;
      if (overflow > DEPTH_OVERFLOW) {
        oldItems = cutOffEvents(oldItems, overflow);
        eventCount -= overflow;
      }
      return new _Branch(oldItems.append(newItems), eventCount);
    }
    remapping(from2, to) {
      let maps = new Mapping();
      this.items.forEach((item, i) => {
        let mirrorPos = item.mirrorOffset != null && i - item.mirrorOffset >= from2 ? maps.maps.length - item.mirrorOffset : void 0;
        maps.appendMap(item.map, mirrorPos);
      }, from2, to);
      return maps;
    }
    addMaps(array) {
      if (this.eventCount == 0)
        return this;
      return new _Branch(this.items.append(array.map((map2) => new Item(map2))), this.eventCount);
    }
    // When the collab module receives remote changes, the history has
    // to know about those, so that it can adjust the steps that were
    // rebased on top of the remote changes, and include the position
    // maps for the remote changes in its array of items.
    rebased(rebasedTransform, rebasedCount) {
      if (!this.eventCount)
        return this;
      rebasedCount = Math.min(this.items.length, rebasedCount);
      let rebasedItems = [], start = this.items.length - rebasedCount;
      let mapping = rebasedTransform.mapping;
      let newUntil = rebasedTransform.steps.length;
      let eventCount = this.eventCount;
      this.items.forEach((item) => {
        if (item.selection)
          eventCount--;
      }, start);
      let iRebased = rebasedCount;
      this.items.forEach((item) => {
        let pos = mapping.getMirror(--iRebased);
        if (pos == null)
          return;
        newUntil = Math.min(newUntil, pos);
        let map2 = mapping.maps[pos];
        if (item.step) {
          let step = rebasedTransform.steps[pos].invert(rebasedTransform.docs[pos]);
          let selection = item.selection && item.selection.map(mapping.slice(iRebased + 1, pos));
          if (selection)
            eventCount++;
          rebasedItems.push(new Item(map2, step, selection));
        } else {
          rebasedItems.push(new Item(map2));
        }
      }, start);
      let newMaps = [];
      for (let i = rebasedCount; i < newUntil; i++)
        newMaps.push(new Item(mapping.maps[i]));
      let items = this.items.slice(0, start).append(newMaps).append(rebasedItems);
      let branch = new _Branch(items, eventCount);
      if (branch.emptyItemCount() > max_empty_items)
        branch = branch.compress(this.items.length - rebasedItems.length);
      return branch;
    }
    emptyItemCount() {
      let count = 0;
      this.items.forEach((item) => {
        if (!item.step)
          count++;
      });
      return count;
    }
    // Compressing a branch means rewriting it to push the air (map-only
    // items) out. During collaboration, these naturally accumulate
    // because each remote change adds one. The `upto` argument is used
    // to ensure that only the items below a given level are compressed,
    // because `rebased` relies on a clean, untouched set of items in
    // order to associate old items with rebased steps.
    compress(upto = this.items.length) {
      let remap = this.remapping(0, upto), mapFrom = remap.maps.length;
      let items = [], events = 0;
      this.items.forEach((item, i) => {
        if (i >= upto) {
          items.push(item);
          if (item.selection)
            events++;
        } else if (item.step) {
          let step = item.step.map(remap.slice(mapFrom)), map2 = step && step.getMap();
          mapFrom--;
          if (map2)
            remap.appendMap(map2, mapFrom);
          if (step) {
            let selection = item.selection && item.selection.map(remap.slice(mapFrom));
            if (selection)
              events++;
            let newItem = new Item(map2.invert(), step, selection), merged, last = items.length - 1;
            if (merged = items.length && items[last].merge(newItem))
              items[last] = merged;
            else
              items.push(newItem);
          }
        } else if (item.map) {
          mapFrom--;
        }
      }, this.items.length, 0);
      return new _Branch(dist_default2.from(items.reverse()), events);
    }
  };
  Branch.empty = new Branch(dist_default2.empty, 0);
  function cutOffEvents(items, n) {
    let cutPoint;
    items.forEach((item, i) => {
      if (item.selection && n-- == 0) {
        cutPoint = i;
        return false;
      }
    });
    return items.slice(cutPoint);
  }
  var Item = class _Item {
    constructor(map2, step, selection, mirrorOffset) {
      this.map = map2;
      this.step = step;
      this.selection = selection;
      this.mirrorOffset = mirrorOffset;
    }
    merge(other) {
      if (this.step && other.step && !other.selection) {
        let step = other.step.merge(this.step);
        if (step)
          return new _Item(step.getMap().invert(), step, this.selection);
      }
    }
  };
  var HistoryState = class {
    constructor(done, undone, prevRanges, prevTime, prevComposition) {
      this.done = done;
      this.undone = undone;
      this.prevRanges = prevRanges;
      this.prevTime = prevTime;
      this.prevComposition = prevComposition;
    }
  };
  var DEPTH_OVERFLOW = 20;
  function applyTransaction(history2, state, tr, options) {
    let historyTr = tr.getMeta(historyKey), rebased;
    if (historyTr)
      return historyTr.historyState;
    if (tr.getMeta(closeHistoryKey))
      history2 = new HistoryState(history2.done, history2.undone, null, 0, -1);
    let appended = tr.getMeta("appendedTransaction");
    if (tr.steps.length == 0) {
      return history2;
    } else if (appended && appended.getMeta(historyKey)) {
      if (appended.getMeta(historyKey).redo)
        return new HistoryState(history2.done.addTransform(tr, void 0, options, mustPreserveItems(state)), history2.undone, rangesFor(tr.mapping.maps), history2.prevTime, history2.prevComposition);
      else
        return new HistoryState(history2.done, history2.undone.addTransform(tr, void 0, options, mustPreserveItems(state)), null, history2.prevTime, history2.prevComposition);
    } else if (tr.getMeta("addToHistory") !== false && !(appended && appended.getMeta("addToHistory") === false)) {
      let composition = tr.getMeta("composition");
      let newGroup = history2.prevTime == 0 || !appended && history2.prevComposition != composition && (history2.prevTime < (tr.time || 0) - options.newGroupDelay || !isAdjacentTo(tr, history2.prevRanges));
      let prevRanges = appended ? mapRanges(history2.prevRanges, tr.mapping) : rangesFor(tr.mapping.maps);
      return new HistoryState(history2.done.addTransform(tr, newGroup ? state.selection.getBookmark() : void 0, options, mustPreserveItems(state)), Branch.empty, prevRanges, tr.time, composition == null ? history2.prevComposition : composition);
    } else if (rebased = tr.getMeta("rebased")) {
      return new HistoryState(history2.done.rebased(tr, rebased), history2.undone.rebased(tr, rebased), mapRanges(history2.prevRanges, tr.mapping), history2.prevTime, history2.prevComposition);
    } else {
      return new HistoryState(history2.done.addMaps(tr.mapping.maps), history2.undone.addMaps(tr.mapping.maps), mapRanges(history2.prevRanges, tr.mapping), history2.prevTime, history2.prevComposition);
    }
  }
  function isAdjacentTo(transform, prevRanges) {
    if (!prevRanges)
      return false;
    if (!transform.docChanged)
      return true;
    let adjacent = false;
    transform.mapping.maps[0].forEach((start, end) => {
      for (let i = 0; i < prevRanges.length; i += 2)
        if (start <= prevRanges[i + 1] && end >= prevRanges[i])
          adjacent = true;
    });
    return adjacent;
  }
  function rangesFor(maps) {
    let result = [];
    for (let i = maps.length - 1; i >= 0 && result.length == 0; i--)
      maps[i].forEach((_from, _to, from2, to) => result.push(from2, to));
    return result;
  }
  function mapRanges(ranges, mapping) {
    if (!ranges)
      return null;
    let result = [];
    for (let i = 0; i < ranges.length; i += 2) {
      let from2 = mapping.map(ranges[i], 1), to = mapping.map(ranges[i + 1], -1);
      if (from2 <= to)
        result.push(from2, to);
    }
    return result;
  }
  function selectionFromChanges(state, tr) {
    for (let i = 0; i < tr.steps.length; i++) {
      let map2 = tr.mapping.maps[i], pos = -1;
      map2.forEach((_start, end) => pos = end);
      if (pos < 0) {
        let step = tr.steps[i];
        if (step instanceof AddMarkStep || step instanceof RemoveMarkStep)
          pos = step.to;
      }
      if (pos > -1)
        return Selection.near(state.doc.resolve(pos));
    }
    return state.selection;
  }
  function histTransaction(history2, state, redo2) {
    let preserveItems = mustPreserveItems(state);
    let histOptions = historyKey.get(state).spec.config;
    let pop = (redo2 ? history2.undone : history2.done).popEvent(state, preserveItems);
    if (!pop)
      return null;
    let selection = pop.selection.resolve(pop.transform.doc);
    let added = (redo2 ? history2.done : history2.undone).addTransform(pop.transform, selectionFromChanges(state, pop.transform).getBookmark(), histOptions, preserveItems);
    let newHist = new HistoryState(redo2 ? added : pop.remaining, redo2 ? pop.remaining : added, null, 0, -1);
    return pop.transform.setSelection(selection).setMeta(historyKey, { redo: redo2, historyState: newHist });
  }
  var cachedPreserveItems = false;
  var cachedPreserveItemsPlugins = null;
  function mustPreserveItems(state) {
    let plugins = state.plugins;
    if (cachedPreserveItemsPlugins != plugins) {
      cachedPreserveItems = false;
      cachedPreserveItemsPlugins = plugins;
      for (let i = 0; i < plugins.length; i++)
        if (plugins[i].spec.historyPreserveItems) {
          cachedPreserveItems = true;
          break;
        }
    }
    return cachedPreserveItems;
  }
  function closeHistory(tr) {
    return tr.setMeta(closeHistoryKey, true);
  }
  var historyKey = new PluginKey("history");
  var closeHistoryKey = new PluginKey("closeHistory");
  function history(config = {}) {
    config = {
      depth: config.depth || 100,
      newGroupDelay: config.newGroupDelay || 500
    };
    return new Plugin({
      key: historyKey,
      state: {
        init() {
          return new HistoryState(Branch.empty, Branch.empty, null, 0, -1);
        },
        apply(tr, hist, state) {
          return applyTransaction(hist, state, tr, config);
        }
      },
      config,
      props: {
        handleDOMEvents: {
          beforeinput(view, e) {
            let inputType = e.inputType;
            let command = inputType == "historyUndo" ? undo : inputType == "historyRedo" ? redo : null;
            if (!command || !view.editable)
              return false;
            e.preventDefault();
            return command(view.state, view.dispatch);
          }
        }
      }
    });
  }
  function buildCommand(redo2, scroll) {
    return (state, dispatch) => {
      let hist = historyKey.getState(state);
      if (!hist || (redo2 ? hist.undone : hist.done).eventCount == 0)
        return false;
      if (dispatch) {
        let tr = histTransaction(hist, state, redo2);
        if (tr)
          dispatch(scroll ? tr.scrollIntoView() : tr);
      }
      return true;
    };
  }
  var undo = buildCommand(false, true);
  var redo = buildCommand(true, true);
  var undoNoScroll = buildCommand(false, false);
  var redoNoScroll = buildCommand(true, false);
  function undoDepth(state) {
    let hist = historyKey.getState(state);
    return hist ? hist.done.eventCount : 0;
  }
  function redoDepth(state) {
    let hist = historyKey.getState(state);
    return hist ? hist.undone.eventCount : 0;
  }

  // node_modules/w3c-keyname/index.js
  var base = {
    8: "Backspace",
    9: "Tab",
    10: "Enter",
    12: "NumLock",
    13: "Enter",
    16: "Shift",
    17: "Control",
    18: "Alt",
    20: "CapsLock",
    27: "Escape",
    32: " ",
    33: "PageUp",
    34: "PageDown",
    35: "End",
    36: "Home",
    37: "ArrowLeft",
    38: "ArrowUp",
    39: "ArrowRight",
    40: "ArrowDown",
    44: "PrintScreen",
    45: "Insert",
    46: "Delete",
    59: ";",
    61: "=",
    91: "Meta",
    92: "Meta",
    106: "*",
    107: "+",
    108: ",",
    109: "-",
    110: ".",
    111: "/",
    144: "NumLock",
    145: "ScrollLock",
    160: "Shift",
    161: "Shift",
    162: "Control",
    163: "Control",
    164: "Alt",
    165: "Alt",
    173: "-",
    186: ";",
    187: "=",
    188: ",",
    189: "-",
    190: ".",
    191: "/",
    192: "`",
    219: "[",
    220: "\\",
    221: "]",
    222: "'"
  };
  var shift = {
    48: ")",
    49: "!",
    50: "@",
    51: "#",
    52: "$",
    53: "%",
    54: "^",
    55: "&",
    56: "*",
    57: "(",
    59: ":",
    61: "+",
    173: "_",
    186: ":",
    187: "+",
    188: "<",
    189: "_",
    190: ">",
    191: "?",
    192: "~",
    219: "{",
    220: "|",
    221: "}",
    222: '"'
  };
  var mac2 = typeof navigator != "undefined" && /Mac/.test(navigator.platform);
  var ie = typeof navigator != "undefined" && /MSIE \d|Trident\/(?:[7-9]|\d{2,})\..*rv:(\d+)/.exec(navigator.userAgent);
  for (i = 0; i < 10; i++) base[48 + i] = base[96 + i] = String(i);
  var i;
  for (i = 1; i <= 24; i++) base[i + 111] = "F" + i;
  var i;
  for (i = 65; i <= 90; i++) {
    base[i] = String.fromCharCode(i + 32);
    shift[i] = String.fromCharCode(i);
  }
  var i;
  for (code in base) if (!shift.hasOwnProperty(code)) shift[code] = base[code];
  var code;
  function keyName(event) {
    var ignoreKey = mac2 && event.metaKey && event.shiftKey && !event.ctrlKey && !event.altKey || ie && event.shiftKey && event.key && event.key.length == 1 || event.key == "Unidentified";
    var name = !ignoreKey && event.key || (event.shiftKey ? shift : base)[event.keyCode] || event.key || "Unidentified";
    if (name == "Esc") name = "Escape";
    if (name == "Del") name = "Delete";
    if (name == "Left") name = "ArrowLeft";
    if (name == "Up") name = "ArrowUp";
    if (name == "Right") name = "ArrowRight";
    if (name == "Down") name = "ArrowDown";
    return name;
  }

  // node_modules/prosemirror-keymap/dist/index.js
  var mac3 = typeof navigator != "undefined" && /Mac|iP(hone|[oa]d)/.test(navigator.platform);
  var windows2 = typeof navigator != "undefined" && /Win/.test(navigator.platform);
  function normalizeKeyName(name) {
    let parts = name.split(/-(?!$)/), result = parts[parts.length - 1];
    if (result == "Space")
      result = " ";
    let alt, ctrl, shift2, meta;
    for (let i = 0; i < parts.length - 1; i++) {
      let mod = parts[i];
      if (/^(cmd|meta|m)$/i.test(mod))
        meta = true;
      else if (/^a(lt)?$/i.test(mod))
        alt = true;
      else if (/^(c|ctrl|control)$/i.test(mod))
        ctrl = true;
      else if (/^s(hift)?$/i.test(mod))
        shift2 = true;
      else if (/^mod$/i.test(mod)) {
        if (mac3)
          meta = true;
        else
          ctrl = true;
      } else
        throw new Error("Unrecognized modifier name: " + mod);
    }
    if (alt)
      result = "Alt-" + result;
    if (ctrl)
      result = "Ctrl-" + result;
    if (meta)
      result = "Meta-" + result;
    if (shift2)
      result = "Shift-" + result;
    return result;
  }
  function normalize(map2) {
    let copy2 = /* @__PURE__ */ Object.create(null);
    for (let prop in map2)
      copy2[normalizeKeyName(prop)] = map2[prop];
    return copy2;
  }
  function modifiers(name, event, shift2 = true) {
    if (event.altKey)
      name = "Alt-" + name;
    if (event.ctrlKey)
      name = "Ctrl-" + name;
    if (event.metaKey)
      name = "Meta-" + name;
    if (shift2 && event.shiftKey)
      name = "Shift-" + name;
    return name;
  }
  function keymap(bindings) {
    return new Plugin({ props: { handleKeyDown: keydownHandler(bindings) } });
  }
  function keydownHandler(bindings) {
    let map2 = normalize(bindings);
    return function(view, event) {
      let name = keyName(event), baseName, direct = map2[modifiers(name, event)];
      if (direct && direct(view.state, view.dispatch, view))
        return true;
      if (name.length == 1 && name != " ") {
        if (event.shiftKey) {
          let noShift = map2[modifiers(name, event, false)];
          if (noShift && noShift(view.state, view.dispatch, view))
            return true;
        }
        if ((event.altKey || event.metaKey || event.ctrlKey) && // Ctrl-Alt may be used for AltGr on Windows
        !(windows2 && event.ctrlKey && event.altKey) && (baseName = base[event.keyCode]) && baseName != name) {
          let fromCode = map2[modifiers(baseName, event)];
          if (fromCode && fromCode(view.state, view.dispatch, view))
            return true;
        }
      }
      return false;
    };
  }

  // node_modules/prosemirror-gapcursor/dist/index.js
  var GapCursor = class _GapCursor extends Selection {
    /**
    Create a gap cursor.
    */
    constructor($pos) {
      super($pos, $pos);
    }
    map(doc3, mapping) {
      let $pos = doc3.resolve(mapping.map(this.head));
      return _GapCursor.valid($pos) ? new _GapCursor($pos) : Selection.near($pos);
    }
    content() {
      return Slice.empty;
    }
    eq(other) {
      return other instanceof _GapCursor && other.head == this.head;
    }
    toJSON() {
      return { type: "gapcursor", pos: this.head };
    }
    /**
    @internal
    */
    static fromJSON(doc3, json) {
      if (typeof json.pos != "number")
        throw new RangeError("Invalid input for GapCursor.fromJSON");
      return new _GapCursor(doc3.resolve(json.pos));
    }
    /**
    @internal
    */
    getBookmark() {
      return new GapBookmark(this.anchor);
    }
    /**
    @internal
    */
    static valid($pos) {
      let parent = $pos.parent;
      if (parent.inlineContent || !closedBefore($pos) || !closedAfter($pos))
        return false;
      let override = parent.type.spec.allowGapCursor;
      if (override != null)
        return override;
      let deflt = parent.contentMatchAt($pos.index()).defaultType;
      return deflt && deflt.isTextblock;
    }
    /**
    @internal
    */
    static findGapCursorFrom($pos, dir, mustMove = false) {
      search: for (; ; ) {
        if (!mustMove && _GapCursor.valid($pos))
          return $pos;
        let pos = $pos.pos, next = null;
        for (let d = $pos.depth; ; d--) {
          let parent = $pos.node(d);
          if (dir > 0 ? $pos.indexAfter(d) < parent.childCount : $pos.index(d) > 0) {
            next = parent.child(dir > 0 ? $pos.indexAfter(d) : $pos.index(d) - 1);
            break;
          } else if (d == 0) {
            return null;
          }
          pos += dir;
          let $cur = $pos.doc.resolve(pos);
          if (_GapCursor.valid($cur))
            return $cur;
        }
        for (; ; ) {
          let inside = dir > 0 ? next.firstChild : next.lastChild;
          if (!inside) {
            if (next.isAtom && !next.isText && !NodeSelection.isSelectable(next)) {
              $pos = $pos.doc.resolve(pos + next.nodeSize * dir);
              mustMove = false;
              continue search;
            }
            break;
          }
          next = inside;
          pos += dir;
          let $cur = $pos.doc.resolve(pos);
          if (_GapCursor.valid($cur))
            return $cur;
        }
        return null;
      }
    }
  };
  GapCursor.prototype.visible = false;
  GapCursor.findFrom = GapCursor.findGapCursorFrom;
  Selection.jsonID("gapcursor", GapCursor);
  var GapBookmark = class _GapBookmark {
    constructor(pos) {
      this.pos = pos;
    }
    map(mapping) {
      return new _GapBookmark(mapping.map(this.pos));
    }
    resolve(doc3) {
      let $pos = doc3.resolve(this.pos);
      return GapCursor.valid($pos) ? new GapCursor($pos) : Selection.near($pos);
    }
  };
  function needsGap(type) {
    return type.isAtom || type.spec.isolating || type.spec.createGapCursor;
  }
  function closedBefore($pos) {
    for (let d = $pos.depth; d >= 0; d--) {
      let index = $pos.index(d), parent = $pos.node(d);
      if (index == 0) {
        if (parent.type.spec.isolating)
          return true;
        continue;
      }
      for (let before = parent.child(index - 1); ; before = before.lastChild) {
        if (before.childCount == 0 && !before.inlineContent || needsGap(before.type))
          return true;
        if (before.inlineContent)
          return false;
      }
    }
    return true;
  }
  function closedAfter($pos) {
    for (let d = $pos.depth; d >= 0; d--) {
      let index = $pos.indexAfter(d), parent = $pos.node(d);
      if (index == parent.childCount) {
        if (parent.type.spec.isolating)
          return true;
        continue;
      }
      for (let after = parent.child(index); ; after = after.firstChild) {
        if (after.childCount == 0 && !after.inlineContent || needsGap(after.type))
          return true;
        if (after.inlineContent)
          return false;
      }
    }
    return true;
  }
  function gapCursor() {
    return new Plugin({
      props: {
        decorations: drawGapCursor,
        createSelectionBetween(_view, $anchor, $head) {
          return $anchor.pos == $head.pos && GapCursor.valid($head) ? new GapCursor($head) : null;
        },
        handleClick,
        handleKeyDown,
        handleDOMEvents: { beforeinput }
      }
    });
  }
  var handleKeyDown = keydownHandler({
    "ArrowLeft": arrow("horiz", -1),
    "ArrowRight": arrow("horiz", 1),
    "ArrowUp": arrow("vert", -1),
    "ArrowDown": arrow("vert", 1)
  });
  function arrow(axis, dir) {
    const dirStr = axis == "vert" ? dir > 0 ? "down" : "up" : dir > 0 ? "right" : "left";
    return function(state, dispatch, view) {
      let sel = state.selection;
      let $start = dir > 0 ? sel.$to : sel.$from, mustMove = sel.empty;
      if (sel instanceof TextSelection) {
        if (!view.endOfTextblock(dirStr) || $start.depth == 0)
          return false;
        mustMove = false;
        $start = state.doc.resolve(dir > 0 ? $start.after() : $start.before());
      }
      let $found = GapCursor.findGapCursorFrom($start, dir, mustMove);
      if (!$found)
        return false;
      if (dispatch)
        dispatch(state.tr.setSelection(new GapCursor($found)));
      return true;
    };
  }
  function handleClick(view, pos, event) {
    if (!view || !view.editable)
      return false;
    let $pos = view.state.doc.resolve(pos);
    if (!GapCursor.valid($pos))
      return false;
    let clickPos = view.posAtCoords({ left: event.clientX, top: event.clientY });
    if (clickPos && clickPos.inside > -1 && NodeSelection.isSelectable(view.state.doc.nodeAt(clickPos.inside)))
      return false;
    view.dispatch(view.state.tr.setSelection(new GapCursor($pos)));
    return true;
  }
  function beforeinput(view, event) {
    if (event.inputType != "insertCompositionText" || !(view.state.selection instanceof GapCursor))
      return false;
    let { $from } = view.state.selection;
    let insert = $from.parent.contentMatchAt($from.index()).findWrapping(view.state.schema.nodes.text);
    if (!insert)
      return false;
    let frag = Fragment.empty;
    for (let i = insert.length - 1; i >= 0; i--)
      frag = Fragment.from(insert[i].createAndFill(null, frag));
    let tr = view.state.tr.replace($from.pos, $from.pos, new Slice(frag, 0, 0));
    tr.setSelection(TextSelection.near(tr.doc.resolve($from.pos + 1)));
    view.dispatch(tr);
    return false;
  }
  function drawGapCursor(state) {
    if (!(state.selection instanceof GapCursor))
      return null;
    let node = document.createElement("div");
    node.className = "ProseMirror-gapcursor";
    return DecorationSet.create(state.doc, [Decoration.widget(state.selection.head, node, { key: "gapcursor" })]);
  }

  // src/schema.js
  var INLINE_HTML_TAGS = ["u", "ins", "small", "sub", "sup", "kbd", "samp", "var", "q", "cite", "abbr", "dfn"];
  var INLINE_HTML_ATTRS = ["title", "dir", "lang"];
  var blockOriginAttrs = () => ({
    mdContext: { default: "" },
    mdBlockId: { default: null },
    mdBlockSub: { default: 0 },
    mdBlockTotal: { default: 1 }
  });
  function readBlockOrigin(dom) {
    return {
      mdContext: dom.getAttribute("data-fastra-md-context") || "",
      mdBlockId: dom.getAttribute("data-fastra-md-block-id") || null,
      mdBlockSub: Number(dom.getAttribute("data-fastra-md-block-sub") || 0),
      mdBlockTotal: Number(dom.getAttribute("data-fastra-md-block-total") || 1)
    };
  }
  function inlineHtmlMarkSpec(tag) {
    return {
      attrs: {
        title: { default: null },
        dir: { default: null },
        lang: { default: null }
      },
      excludes: "",
      parseDOM: [{
        tag,
        getAttrs(dom) {
          if (dom.closest?.("[data-md-opaque],[data-tex],pre")) return false;
          return {
            title: dom.getAttribute("title"),
            dir: dom.getAttribute("dir"),
            lang: dom.getAttribute("lang")
          };
        }
      }],
      toDOM(mark) {
        const attrs = {};
        for (const name of INLINE_HTML_ATTRS) {
          if (mark.attrs[name] != null && mark.attrs[name] !== "") {
            attrs[name] = mark.attrs[name];
          }
        }
        return [tag, attrs, 0];
      }
    };
  }
  var nodes = {
    doc: {
      content: "block+",
      attrs: {
        sourceContext: { default: "" }
      }
    },
    paragraph: {
      content: "inline*",
      group: "block",
      attrs: {
        ...blockOriginAttrs(),
        mdEmpty: { default: false },
        mdDeleted: { default: false }
      },
      parseDOM: [{
        tag: "p",
        getAttrs(dom) {
          if (dom.hasAttribute("data-md-edit-boundary")) return false;
          return {
            ...readBlockOrigin(dom),
            mdEmpty: dom.hasAttribute("data-md-empty")
          };
        }
      }],
      toDOM(node) {
        const attrs = {};
        if (node.attrs.mdEmpty && node.content.size === 0) {
          attrs["data-md-empty"] = "true";
        }
        return ["p", attrs, 0];
      }
    },
    blank_line: {
      content: "inline*",
      group: "block",
      attrs: blockOriginAttrs(),
      parseDOM: [{
        tag: "div.fastra-visible-blank-line",
        getAttrs(dom) {
          return readBlockOrigin(dom);
        }
      }],
      toDOM() {
        return ["div", { class: "fastra-visible-blank-line" }, 0];
      }
    },
    heading: {
      content: "inline*",
      group: "block",
      defining: true,
      attrs: {
        ...blockOriginAttrs(),
        level: { default: 1 },
        outlineIgnore: { default: false }
      },
      parseDOM: [1, 2, 3, 4, 5, 6].map((level) => ({
        tag: `h${level}`,
        getAttrs(dom) {
          return {
            ...readBlockOrigin(dom),
            level,
            outlineIgnore: dom.hasAttribute("data-md-outline-ignore")
          };
        }
      })),
      toDOM(node) {
        const attrs = {};
        if (node.attrs.outlineIgnore) attrs["data-md-outline-ignore"] = "true";
        return [`h${node.attrs.level}`, attrs, 0];
      }
    },
    blockquote: {
      content: "block+",
      group: "block",
      defining: true,
      attrs: blockOriginAttrs(),
      parseDOM: [{
        tag: "blockquote",
        getAttrs(dom) {
          return readBlockOrigin(dom);
        }
      }],
      toDOM() {
        return ["blockquote", 0];
      }
    },
    bullet_list: {
      content: "list_item+",
      group: "block",
      attrs: {
        ...blockOriginAttrs(),
        tight: { default: true }
      },
      parseDOM: [{
        tag: "ul",
        getAttrs(dom) {
          return {
            ...readBlockOrigin(dom),
            tight: !dom.querySelector(":scope > li > p")
          };
        }
      }],
      toDOM() {
        return ["ul", 0];
      }
    },
    ordered_list: {
      content: "list_item+",
      group: "block",
      attrs: {
        ...blockOriginAttrs(),
        order: { default: 1 },
        tight: { default: true }
      },
      parseDOM: [{
        tag: "ol",
        getAttrs(dom) {
          const start = dom.getAttribute("start")?.trim();
          const order = start && /^[+-]?\d+$/.test(start) ? Number(start) : 1;
          return {
            ...readBlockOrigin(dom),
            order: Number.isSafeInteger(order) ? Math.max(0, order) : 1,
            tight: !dom.querySelector(":scope > li > p")
          };
        }
      }],
      toDOM(node) {
        return node.attrs.order === 1 ? ["ol", 0] : ["ol", { start: String(node.attrs.order) }, 0];
      }
    },
    list_item: {
      content: "block+",
      defining: true,
      attrs: {
        task: { default: null }
      },
      parseDOM: [{
        tag: "li",
        getAttrs(dom) {
          const task = dom.getAttribute("data-task");
          if (task === "checked" || task === "unchecked") return { task: task === "checked" };
          const cb = Array.from(dom.querySelectorAll("input[type=checkbox]")).find((n) => n.closest("li") === dom);
          if (!cb) return { task: null };
          return { task: cb.hasAttribute("checked") || cb.checked === true };
        }
      }],
      toDOM(node) {
        if (node.attrs.task !== null) {
          return ["li", { "data-task": node.attrs.task ? "checked" : "unchecked" }, 0];
        }
        return ["li", 0];
      }
    },
    code_block: {
      content: "text*",
      marks: "",
      group: "block",
      code: true,
      defining: true,
      attrs: {
        ...blockOriginAttrs(),
        language: { default: "" }
      },
      parseDOM: [{
        tag: "pre",
        preserveWhitespace: "full",
        getAttrs(dom) {
          if (dom.closest("[data-md-opaque]") || dom.classList.contains("mermaid-render")) return false;
          const code = dom.querySelector("code");
          const lang = code?.className.match(/(?:^|\s)language-([\w+-]+)/)?.[1] || "";
          return {
            ...readBlockOrigin(dom),
            language: lang
          };
        }
      }],
      toDOM(node) {
        const codeAttrs = node.attrs.language ? { class: `language-${node.attrs.language}` } : {};
        return ["pre", ["code", codeAttrs, 0]];
      }
    },
    horizontal_rule: {
      group: "block",
      atom: true,
      attrs: blockOriginAttrs(),
      parseDOM: [{
        tag: "hr",
        getAttrs(dom) {
          return readBlockOrigin(dom);
        }
      }],
      toDOM() {
        return ["hr"];
      }
    },
    table: {
      content: "table_row+",
      group: "block",
      isolating: true,
      attrs: {
        ...blockOriginAttrs(),
        gfm: { default: true }
      },
      parseDOM: [{
        tag: "table",
        getAttrs(dom) {
          const hasMerged = !!dom.querySelector("[colspan],[rowspan],table");
          const gfm = dom.getAttribute("data-md-table") === "gfm" && !hasMerged;
          return {
            ...readBlockOrigin(dom),
            gfm
          };
        }
      }],
      toDOM(node) {
        const attrs = node.attrs.gfm ? { "data-md-table": "gfm" } : {};
        return ["table", attrs, ["tbody", 0]];
      }
    },
    table_row: {
      content: "(table_header | table_cell)+",
      parseDOM: [{ tag: "tr" }],
      toDOM() {
        return ["tr", 0];
      }
    },
    table_header: {
      content: "inline*",
      isolating: true,
      attrs: {
        align: { default: null },
        colspan: { default: 1 },
        rowspan: { default: 1 }
      },
      parseDOM: [{
        tag: "th",
        preserveWhitespace: "full",
        getAttrs(dom) {
          return {
            align: dom.getAttribute("align") || null,
            colspan: Math.max(1, Number(dom.getAttribute("colspan") || 1)),
            rowspan: Math.max(1, Number(dom.getAttribute("rowspan") || 1))
          };
        }
      }],
      toDOM(node) {
        const attrs = {};
        if (node.attrs.align) attrs.align = node.attrs.align;
        if (node.attrs.colspan > 1) attrs.colspan = String(node.attrs.colspan);
        if (node.attrs.rowspan > 1) attrs.rowspan = String(node.attrs.rowspan);
        return ["th", attrs, 0];
      }
    },
    table_cell: {
      content: "inline*",
      isolating: true,
      attrs: {
        align: { default: null },
        colspan: { default: 1 },
        rowspan: { default: 1 }
      },
      parseDOM: [{
        tag: "td",
        preserveWhitespace: "full",
        getAttrs(dom) {
          return {
            align: dom.getAttribute("align") || null,
            colspan: Math.max(1, Number(dom.getAttribute("colspan") || 1)),
            rowspan: Math.max(1, Number(dom.getAttribute("rowspan") || 1))
          };
        }
      }],
      toDOM(node) {
        const attrs = {};
        if (node.attrs.align) attrs.align = node.attrs.align;
        if (node.attrs.colspan > 1) attrs.colspan = String(node.attrs.colspan);
        if (node.attrs.rowspan > 1) attrs.rowspan = String(node.attrs.rowspan);
        return ["td", attrs, 0];
      }
    },
    math_block: {
      group: "block",
      atom: true,
      selectable: true,
      attrs: {
        ...blockOriginAttrs(),
        tex: { default: "" },
        mathSourceKey: { default: null }
      },
      parseDOM: [{
        tag: "div[data-tex]",
        priority: 60,
        getAttrs(dom) {
          return {
            ...readBlockOrigin(dom),
            tex: dom.getAttribute("data-tex") || "",
            mathSourceKey: dom.getAttribute("data-md-math-source") || null
          };
        }
      }],
      toDOM(node) {
        const attrs = {
          class: "math-block",
          "data-tex": node.attrs.tex,
          contenteditable: "false"
        };
        if (node.attrs.mathSourceKey) attrs["data-md-math-source"] = node.attrs.mathSourceKey;
        return ["div", attrs, node.attrs.tex];
      }
    },
    opaque_block: {
      group: "block",
      atom: true,
      selectable: true,
      attrs: {
        ...blockOriginAttrs(),
        opaqueKey: { default: "" },
        tag: { default: "section" },
        className: { default: "" },
        mathSourceKey: { default: null },
        rawHTML: { default: "" }
      },
      parseDOM: [{
        tag: "[data-md-opaque]",
        priority: 65,
        getAttrs(dom) {
          if (!["DIV", "SECTION", "PRE"].includes(dom.tagName)) return false;
          return {
            ...readBlockOrigin(dom),
            opaqueKey: dom.getAttribute("data-md-opaque") || "",
            tag: dom.tagName.toLowerCase(),
            className: dom.getAttribute("class") || "",
            mathSourceKey: dom.getAttribute("data-md-math-source") || null,
            rawHTML: dom.innerHTML
          };
        }
      }],
      toDOM(node) {
        const attrs = {
          "data-md-opaque": node.attrs.opaqueKey,
          contenteditable: "false"
        };
        if (node.attrs.className) attrs.class = node.attrs.className;
        if (node.attrs.mathSourceKey) attrs["data-md-math-source"] = node.attrs.mathSourceKey;
        return [node.attrs.tag || "section", attrs];
      }
    },
    text: {
      group: "inline"
    },
    hard_break: {
      inline: true,
      group: "inline",
      selectable: false,
      parseDOM: [{
        tag: "br",
        getAttrs(dom) {
          if (dom.closest("[data-md-opaque],[data-tex],pre")) return false;
          return {};
        }
      }],
      toDOM() {
        return ["br"];
      }
    },
    image: {
      inline: true,
      group: "inline",
      draggable: true,
      attrs: {
        src: { default: "" },
        mdSrc: { default: null },
        alt: { default: "" },
        title: { default: null },
        width: { default: null },
        height: { default: null },
        imageTransaction: { default: null },
        imageEnding: { default: null }
      },
      parseDOM: [{
        tag: "img",
        getAttrs(dom) {
          if (dom.closest("[data-md-opaque],[data-tex],pre")) return false;
          return {
            src: dom.getAttribute("src") || "",
            mdSrc: dom.getAttribute("data-md-src") || null,
            alt: dom.getAttribute("alt") || "",
            title: dom.getAttribute("title"),
            width: dom.getAttribute("width") || null,
            height: dom.getAttribute("height") || null,
            imageTransaction: dom.getAttribute("data-md-image-transaction") || null,
            imageEnding: dom.getAttribute("data-md-image-ending") || null
          };
        }
      }],
      toDOM(node) {
        const attrs = {
          src: node.attrs.src || "",
          alt: node.attrs.alt || ""
        };
        if (node.attrs.mdSrc != null) attrs["data-md-src"] = node.attrs.mdSrc;
        if (node.attrs.title != null && node.attrs.title !== "") attrs.title = node.attrs.title;
        if (node.attrs.width != null && node.attrs.width !== "") attrs.width = node.attrs.width;
        if (node.attrs.height != null && node.attrs.height !== "") attrs.height = node.attrs.height;
        if (node.attrs.imageTransaction) attrs["data-md-image-transaction"] = node.attrs.imageTransaction;
        if (node.attrs.imageEnding) attrs["data-md-image-ending"] = node.attrs.imageEnding;
        return ["img", attrs];
      }
    },
    math_inline: {
      inline: true,
      group: "inline",
      atom: true,
      selectable: true,
      attrs: {
        tex: { default: "" },
        mathSourceKey: { default: null },
        displayMode: { default: false }
      },
      parseDOM: [{
        tag: "span[data-tex]",
        priority: 60,
        getAttrs(dom) {
          return {
            tex: dom.getAttribute("data-tex") || "",
            mathSourceKey: dom.getAttribute("data-md-math-source") || null,
            displayMode: dom.classList.contains("math-block")
          };
        }
      }],
      toDOM(node) {
        const attrs = {
          class: node.attrs.displayMode ? "math-block" : "math-inline",
          "data-tex": node.attrs.tex,
          contenteditable: "false"
        };
        if (node.attrs.mathSourceKey) attrs["data-md-math-source"] = node.attrs.mathSourceKey;
        return ["span", attrs, node.attrs.tex];
      }
    },
    opaque_inline: {
      inline: true,
      group: "inline",
      atom: true,
      selectable: true,
      attrs: {
        opaqueKey: { default: "" },
        tag: { default: "span" },
        className: { default: "" },
        mathSourceKey: { default: null },
        rawHTML: { default: "" }
      },
      parseDOM: [{
        tag: "span[data-md-opaque], mark[data-md-opaque]",
        priority: 65,
        getAttrs(dom) {
          return {
            opaqueKey: dom.getAttribute("data-md-opaque") || "",
            tag: dom.tagName.toLowerCase(),
            className: dom.getAttribute("class") || "",
            mathSourceKey: dom.getAttribute("data-md-math-source") || null,
            rawHTML: dom.innerHTML
          };
        }
      }],
      toDOM(node) {
        const attrs = {
          "data-md-opaque": node.attrs.opaqueKey,
          contenteditable: "false"
        };
        if (node.attrs.className) attrs.class = node.attrs.className;
        if (node.attrs.mathSourceKey) attrs["data-md-math-source"] = node.attrs.mathSourceKey;
        return [node.attrs.tag || "span", attrs];
      }
    }
  };
  var marks = {
    strong: {
      parseDOM: [
        { tag: "strong", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") ? false : null },
        { tag: "b", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") || d.style?.fontWeight === "normal" ? false : null },
        {
          style: "font-weight",
          getAttrs: (value) => /^(bold(er)?|[6-9]\d{2})$/.test(String(value)) ? null : false
        }
      ],
      toDOM() {
        return ["strong", 0];
      }
    },
    em: {
      parseDOM: [
        { tag: "em", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") ? false : null },
        { tag: "i", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") ? false : null },
        { style: "font-style=italic" },
        { style: "font-style=oblique" }
      ],
      toDOM() {
        return ["em", 0];
      }
    },
    code: {
      excludes: "",
      parseDOM: [{
        tag: "code",
        preserveWhitespace: "full",
        getAttrs(dom) {
          if (dom.closest("pre,[data-md-opaque],[data-tex]")) return false;
          return null;
        }
      }],
      toDOM() {
        return ["code", 0];
      }
    },
    highlight: {
      parseDOM: [
        {
          tag: "mark",
          getAttrs(dom) {
            if (dom.closest("[data-md-opaque],[data-tex],pre") || dom.hasAttribute("data-md-opaque")) return false;
            return null;
          }
        },
        {
          style: "background-color",
          getAttrs(value) {
            if (!value || value === "transparent" || value === "rgba(0, 0, 0, 0)") return false;
            return null;
          }
        }
      ],
      toDOM() {
        return ["mark", 0];
      }
    },
    strike: {
      parseDOM: [
        { tag: "del", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") ? false : null },
        { tag: "s", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") ? false : null },
        { tag: "strike", getAttrs: (d) => d.closest("[data-md-opaque],[data-tex],pre") ? false : null },
        {
          style: "text-decoration-line",
          getAttrs: (value) => String(value).includes("line-through") ? null : false
        }
      ],
      toDOM() {
        return ["del", 0];
      }
    },
    link: {
      attrs: {
        href: { default: "" },
        title: { default: null }
      },
      inclusive: false,
      parseDOM: [{
        tag: "a[href]",
        getAttrs(dom) {
          if (dom.closest("[data-md-opaque],[data-tex],pre")) return false;
          return {
            href: dom.getAttribute("href") || "",
            title: dom.getAttribute("title")
          };
        }
      }],
      toDOM(mark) {
        const attrs = { href: mark.attrs.href };
        if (mark.attrs.title != null && mark.attrs.title !== "") attrs.title = mark.attrs.title;
        return ["a", attrs, 0];
      }
    }
  };
  for (const tag of INLINE_HTML_TAGS) {
    marks[`html_${tag}`] = inlineHtmlMarkSpec(tag);
  }
  var schema = new Schema({ nodes, marks });
  var INLINE_HTML_MARK_NAMES = INLINE_HTML_TAGS.map((t) => `html_${t}`);

  // src/parser.js
  var INLINE_WRAP_TAGS = /* @__PURE__ */ new Set(["STRONG", "B", "EM", "I", "MARK", "DEL", "S", "STRIKE", "SPAN", "FONT"]);
  var ALLOWED_PASTE_ATTRS = /* @__PURE__ */ new Set(["href", "src", "alt", "title", "align", "colspan", "rowspan", "start", "type", "checked", "data-md-table", "data-task"]);
  var ALLOWED_CLIPBOARD_TAGS = /* @__PURE__ */ new Set([
    "P",
    "DIV",
    "BR",
    "STRONG",
    "B",
    "EM",
    "I",
    "MARK",
    "DEL",
    "S",
    "STRIKE",
    "U",
    "INS",
    "SMALL",
    "SUB",
    "SUP",
    "KBD",
    "SAMP",
    "VAR",
    "Q",
    "CITE",
    "H1",
    "H2",
    "H3",
    "H4",
    "H5",
    "H6",
    "UL",
    "OL",
    "LI",
    "BLOCKQUOTE",
    "PRE",
    "CODE",
    "A",
    "TABLE",
    "THEAD",
    "TBODY",
    "TFOOT",
    "TR",
    "TD",
    "TH",
    "SPAN",
    "FONT"
  ]);
  function preprocessDOMForParse(container, { stripBlockOrigin = false } = {}) {
    if (!container) return;
    const doc3 = container.ownerDocument;
    container.querySelectorAll("[data-md-edit-boundary]").forEach((n) => n.remove());
    if (stripBlockOrigin) {
      container.querySelectorAll("[data-fastra-md-block-id],[data-fastra-md-context]").forEach((n) => {
        n.removeAttribute("data-fastra-md-context");
        n.removeAttribute("data-fastra-md-block-id");
        n.removeAttribute("data-fastra-md-block-sub");
        n.removeAttribute("data-fastra-md-block-total");
      });
    }
    container.querySelectorAll("pre code").forEach((code) => {
      if (!code.closest("[data-md-opaque],[data-tex]")) code.textContent = code.textContent;
    });
    container.querySelectorAll("div.fastra-visible-blank-line, p[data-md-empty]").forEach((el) => {
      const children = Array.from(el.childNodes);
      if (children.length === 1 && children[0].nodeName === "BR") {
        children[0].remove();
      } else {
        const meaning = Array.from(el.childNodes).filter((n) => !(n.nodeType === 3 && !n.data.replace(/\u200b/g, "").length));
        if (meaning.length === 1 && meaning[0].nodeName === "BR") {
          meaning[0].remove();
        }
      }
    });
    container.querySelectorAll("span[data-md-spaces]").forEach((span) => {
      const count = Math.max(1, Number(span.getAttribute("data-md-spaces") || 1));
      span.replaceWith(doc3.createTextNode("\xA0".repeat(count)));
    });
    container.querySelectorAll("td, th").forEach((cell) => {
      const blocks = Array.from(cell.querySelectorAll("p, div"));
      if (!blocks.length) return;
      for (let i = 0; i < blocks.length; i++) {
        const b = blocks[i];
        if (!cell.contains(b) || b.closest("[data-md-opaque],[data-tex]")) continue;
        const frag = doc3.createDocumentFragment();
        while (b.firstChild) frag.appendChild(b.firstChild);
        if (i + 1 < blocks.length && blocks[i + 1].parentNode === b.parentNode) {
          frag.appendChild(doc3.createElement("br"));
        }
        b.replaceWith(frag);
      }
    });
    const walker = doc3.createTreeWalker(
      container,
      4
      /* NodeFilter.SHOW_TEXT */
    );
    const texts = [];
    while (walker.nextNode()) texts.push(walker.currentNode);
    for (const t of texts) {
      if (t.parentElement?.closest("pre,code,[data-md-opaque],[data-tex]")) continue;
      if (t.data.includes("\u200B")) t.data = t.data.replace(/\u200b/g, "");
    }
  }
  function normalizeLooseBlankDivs(container, { convertEmptyParagraphs = false } = {}) {
    const doc3 = container.ownerDocument;
    container.querySelectorAll("div:not([data-md-block]):not([data-md-opaque]):not([data-tex]), p").forEach((el) => {
      if (el.classList.contains("fastra-visible-blank-line")) return;
      if (el.closest("[data-md-opaque],[data-tex],pre,table,li")) return;
      if (el.hasAttribute("data-md-empty")) return;
      if (el.textContent.replace(/\u200b/g, "").length) return;
      if (el.querySelector("p,div,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,table,pre,code,img,input,hr,[data-md-opaque],[data-tex]")) return;
      const onlyInline = Array.from(el.querySelectorAll("*")).every((c) => c.tagName === "BR" || INLINE_WRAP_TAGS.has(c.tagName));
      if (!onlyInline) return;
      const rawBrCount = el.querySelectorAll("br").length;
      if (el.tagName === "P" && rawBrCount < 2 && !convertEmptyParagraphs) return;
      const brCount = Math.max(1, rawBrCount);
      const frag = doc3.createDocumentFragment();
      for (let i = 0; i < brCount; i++) {
        const blank = doc3.createElement("div");
        blank.className = "fastra-visible-blank-line";
        frag.appendChild(blank);
      }
      el.replaceWith(frag);
    });
  }
  function stampBlockOriginOnNode(node, mdContext, mdBlockId, mdBlockSub, mdBlockTotal) {
    if (!node.type.spec.attrs || !("mdBlockId" in node.type.spec.attrs)) return node;
    return node.type.create(
      {
        ...node.attrs,
        mdContext,
        mdBlockId,
        mdBlockSub,
        mdBlockTotal
      },
      node.content,
      node.marks
    );
  }
  function stripOriginFromNode(node) {
    let attrs = node.attrs;
    if (attrs && ("mdBlockId" in attrs || "mdContext" in attrs)) {
      attrs = { ...attrs, mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 };
    }
    if (!node.content.size) {
      return attrs === node.attrs ? node : node.type.create(attrs, node.content, node.marks);
    }
    const children = [];
    let changed = attrs !== node.attrs;
    node.content.forEach((child) => {
      const cleaned = stripOriginFromNode(child);
      if (cleaned !== child) changed = true;
      children.push(cleaned);
    });
    return changed ? node.type.create(attrs, Fragment.fromArray(children), node.marks) : node;
  }
  function canonicalNodeSnapshot(node) {
    if (node.isText) {
      return {
        type: "text",
        text: node.text,
        marks: node.marks.map((m) => ({ type: m.type.name, attrs: m.attrs }))
      };
    }
    const attrs = {};
    for (const [key, value] of Object.entries(node.attrs || {})) {
      if (key === "mdContext" || key === "mdBlockId" || key === "mdBlockSub" || key === "mdBlockTotal" || key === "outlineIgnore" || key === "rawHTML") {
        continue;
      }
      if (node.type.name === "image" && key === "src" && node.attrs.mdSrc != null) {
        continue;
      }
      attrs[key] = value;
    }
    const children = [];
    node.content.forEach((child) => children.push(canonicalNodeSnapshot(child)));
    return {
      type: node.type.name,
      attrs,
      marks: node.marks.map((m) => ({ type: m.type.name, attrs: m.attrs })),
      content: children
    };
  }
  function canonicalGroupStructure(nodes2) {
    function nodeSignature(node) {
      if (node.isText) return "";
      if (node.type.name === "hard_break") return "(BR)";
      if (node.isLeaf) return `(${node.type.name})`;
      const inner = [];
      node.content.forEach((child) => inner.push(nodeSignature(child)));
      return `(${node.type.name}${inner.join("")})`;
    }
    return nodes2.map(nodeSignature).join("");
  }
  function findUnusedSentinel(text) {
    for (const ch of ["\uE001", "\uE002", "\uF001", "\uF002"]) {
      if (!text.includes(ch)) return ch;
    }
    return "\uE003FASTRACODESPACE\uE004";
  }
  function parseWithInlineCodeSpaces(wrapper, pmParser) {
    const inlineCodes = Array.from(wrapper.querySelectorAll("code")).filter(
      (c) => !c.closest("pre,[data-md-opaque],[data-tex]")
    );
    const inlineTextContainers = Array.from(wrapper.querySelectorAll("p,h1,h2,h3,h4,h5,h6,li,td,th,blockquote"));
    const doc3 = wrapper.ownerDocument;
    const rawText = wrapper.textContent || "";
    const hasDoubleSpaces = inlineTextContainers.some((el) => / {2,}/.test(el.textContent || ""));
    let sentinel = null;
    if (inlineCodes.length || hasDoubleSpaces) {
      sentinel = findUnusedSentinel(rawText);
      for (const code of inlineCodes) {
        const walker = doc3.createTreeWalker(
          code,
          4
          /* NodeFilter.SHOW_TEXT */
        );
        while (walker.nextNode()) {
          if (walker.currentNode.data.includes(" ")) {
            walker.currentNode.data = walker.currentNode.data.replace(/ /g, sentinel);
          }
        }
      }
      if (hasDoubleSpaces) {
        const walker = doc3.createTreeWalker(
          wrapper,
          4
          /* NodeFilter.SHOW_TEXT */
        );
        while (walker.nextNode()) {
          const tn = walker.currentNode;
          if (tn.parentElement?.closest("pre,code,[data-md-opaque],[data-tex]")) continue;
          if (new RegExp("(?<=\\S)( {2,})(?=\\S)").test(tn.data)) {
            tn.data = tn.data.replace(new RegExp("(?<=\\S)( {2,})(?=\\S)", "g"), (m) => sentinel.repeat(m.length));
          }
        }
      }
    }
    const parsed = pmParser.parse(wrapper);
    if (!sentinel) return parsed;
    function restoreNode(node) {
      if (node.isText) {
        return node.text.includes(sentinel) ? node.withText(node.text.replaceAll(sentinel, " ")) : node;
      }
      if (!node.content.size) return node;
      const kids = [];
      let changed = false;
      node.content.forEach((child) => {
        const next = restoreNode(child);
        if (next !== child) changed = true;
        kids.push(next);
      });
      return changed ? node.type.create(node.attrs, Fragment.fromArray(kids), node.marks) : node;
    }
    return restoreNode(parsed);
  }
  function parseDocumentContainer(container, blocks, {
    schema: schema2 = schema,
    mdContext = "",
    ownerDocument = container.ownerDocument
  } = {}) {
    const pmParser = DOMParser.fromSchema(schema2);
    const work = container.cloneNode(true);
    preprocessDOMForParse(work);
    normalizeLooseBlankDivs(work);
    const blockMap = /* @__PURE__ */ new Map();
    for (const b of blocks || []) {
      if (!b.hidden) blockMap.set(String(b.id), b);
    }
    const topNodes = [];
    const parsedGroups = /* @__PURE__ */ new Map();
    for (const child of Array.from(work.childNodes)) {
      if (child.nodeType === 3) {
        if (!child.data.trim()) continue;
        const p = ownerDocument.createElement("p");
        p.textContent = child.data;
        const parsed = pmParser.parse(p);
        parsed.content.forEach((n) => topNodes.push(n));
        continue;
      }
      if (child.nodeType !== 1) continue;
      const blockId = child.getAttribute("data-md-block");
      if (blockId != null) {
        const subHolder = ownerDocument.createElement("div");
        while (child.firstChild) subHolder.appendChild(child.firstChild);
        normalizeLooseBlankDivs(subHolder);
        const parsedSub = subHolder.childNodes.length ? parseWithInlineCodeSpaces(subHolder, pmParser) : schema2.nodes.doc.create(null, schema2.nodes.paragraph.create({ mdEmpty: true }));
        const group = [];
        const total = parsedSub.content.childCount;
        parsedSub.content.forEach((n, _offset, idx) => {
          const stamped = stampBlockOriginOnNode(n, mdContext, blockId, idx, total);
          group.push(stamped);
          topNodes.push(stamped);
        });
        const original = blockMap.get(blockId);
        if (original) {
          const escapeSelector = typeof CSS !== "undefined" && CSS.escape ? CSS.escape(blockId) : blockId.replace(/([^\w-])/g, "\\$1");
          const origDomNode = container.querySelector(`[data-md-block="${escapeSelector}"]`);
          const ignoredHeadings = origDomNode ? Array.from(origDomNode.querySelectorAll("h1,h2,h3,h4,h5,h6")).flatMap((h, i) => h.hasAttribute("data-md-outline-ignore") ? [i] : []) : [];
          parsedGroups.set(blockId, {
            nodes: group,
            canonicalSnapshot: JSON.stringify(group.map(canonicalNodeSnapshot)),
            structure: canonicalGroupStructure(group),
            ignoredHeadings
          });
        }
      } else {
        const subHolder = ownerDocument.createElement("div");
        subHolder.appendChild(child.cloneNode(true));
        const parsed = parseWithInlineCodeSpaces(subHolder, pmParser);
        parsed.content.forEach((n) => topNodes.push(n));
      }
    }
    if (!topNodes.length) {
      topNodes.push(schema2.nodes.paragraph.create({ mdEmpty: true }));
    }
    if (!parsedGroups.size) {
      const visibleBlocks = (blocks || []).filter((b) => !b.hidden);
      if (visibleBlocks.length && visibleBlocks.length === topNodes.length) {
        topNodes.forEach((node, idx) => {
          const b = visibleBlocks[idx];
          const bid = String(b.id);
          const stamped = stampBlockOriginOnNode(node, mdContext, bid, 0, 1);
          topNodes[idx] = stamped;
          parsedGroups.set(bid, {
            nodes: [stamped],
            canonicalSnapshot: JSON.stringify([canonicalNodeSnapshot(stamped)]),
            structure: canonicalGroupStructure([stamped]),
            ignoredHeadings: []
          });
        });
      }
    }
    const doc3 = schema2.nodes.doc.create({ sourceContext: mdContext }, topNodes);
    return { doc: doc3, parsedGroups };
  }
  function parseHTMLToNodes(html, { schema: schema2 = schema, ownerDocument = document } = {}) {
    const template = ownerDocument.createElement("template");
    template.innerHTML = html || "";
    preprocessDOMForParse(template.content, { stripBlockOrigin: true });
    const topBlockCount = Array.from(template.content.childNodes).filter(
      (n) => n.nodeType === 1 || n.nodeType === 3 && n.data.trim()
    ).length;
    const hasBlankParagraph = topBlockCount > 1 || Array.from(template.content.querySelectorAll("p")).some(
      (p) => !p.textContent.replace(/\u200b/g, "").length && p.querySelector("br") && !p.querySelector("img,[data-tex],[data-md-opaque]")
    );
    normalizeLooseBlankDivs(template.content, { convertEmptyParagraphs: hasBlankParagraph });
    const wrapper = ownerDocument.createElement("div");
    wrapper.appendChild(template.content.cloneNode(true));
    const parsed = parseWithInlineCodeSpaces(wrapper, DOMParser.fromSchema(schema2));
    const nodes2 = [];
    parsed.content.forEach((n) => nodes2.push(stripOriginFromNode(n)));
    return nodes2;
  }
  function clipboardURL(value, scheme, relative = false) {
    const url = value.trim();
    if (!url || /[\s\\\u0000-\u001f\u007f]/.test(url) || /[\u0000-\u001f\u007f]/.test(value)) return null;
    if (scheme.test(url) || relative && !url.startsWith("/") && /^[^:/]+(?:\/|$)/.test(url)) return url;
    return null;
  }
  function inlineClipboardStyles(node) {
    if (node.tagName !== "SPAN" && node.tagName !== "FONT" || node.closest("pre,code") || !node.style) return [];
    const { backgroundColor, fontWeight, fontStyle, textDecorationLine } = node.style;
    return [
      backgroundColor && !["transparent", "rgba(0, 0, 0, 0)"].includes(backgroundColor) && "mark",
      textDecorationLine?.includes("line-through") && "del",
      (fontWeight === "bold" || Number(fontWeight) >= 600) && "strong",
      (fontStyle === "italic" || fontStyle === "oblique") && "em"
    ].filter(Boolean);
  }
  function replaceStyledInline(node, tags, ownerDocument) {
    let content = ownerDocument.createDocumentFragment();
    content.append(...node.childNodes);
    for (const tag of tags) {
      const wrap2 = ownerDocument.createElement(tag);
      wrap2.append(content);
      content = wrap2;
    }
    node.replaceWith(content);
  }
  function sanitizePasteHTML(html, ownerDocument = document) {
    const template = ownerDocument.createElement("template");
    template.innerHTML = html || "";
    template.content.querySelectorAll("script,style,iframe,object,embed,svg,math,link,meta,template").forEach((n) => n.remove());
    template.content.querySelectorAll("*").forEach((n) => {
      const language = n.tagName === "CODE" ? n.className.match(/(?:^|\s)language-([\w+-]+)(?=\s|$)/)?.[1] : null;
      const styles = inlineClipboardStyles(n);
      for (const a of Array.from(n.attributes)) {
        if (!ALLOWED_PASTE_ATTRS.has(a.name)) n.removeAttribute(a.name);
      }
      if (language) n.className = "language-" + language;
      if (n.tagName === "IMG") {
        const src = clipboardURL(n.getAttribute("src") || "", /^https?:\/\//i, true);
        if (src === null) n.remove();
        else {
          n.setAttribute("src", src);
          n.dataset.mdSrc = src;
        }
      }
      if (n.hasAttribute("href")) {
        const href = clipboardURL(n.getAttribute("href"), /^(?:https?:\/\/|mailto:|#)/i, true);
        if (href === null) n.removeAttribute("href");
        else n.setAttribute("href", href);
      }
      if (styles.length) replaceStyledInline(n, styles, ownerDocument);
    });
    return template.innerHTML;
  }
  function inspectAndCleanClipboardHTML(html, collectImages = false, ownerDocument = document) {
    const images = [];
    if (new TextEncoder().encode(html || "").length > 2097152) return { ok: false, reason: "size" };
    const template = ownerDocument.createElement("template");
    template.innerHTML = html || "";
    const nodes2 = Array.from(template.content.querySelectorAll("*"));
    if (nodes2.length > 2e4) return { ok: false, reason: "size" };
    for (const node of nodes2) {
      if (collectImages && node.tagName === "IMG") {
        const source = node.getAttribute("src") || "";
        const match = source.match(/^data:image\/(png|jpeg|gif|webp|tiff);base64,([A-Za-z0-9+/]+={0,2})$/i);
        if (!match || images.length >= 32 || match[2].length % 4) return { ok: false, reason: "images" };
        const ext = { jpeg: "jpg" }[match[1].toLowerCase()] || match[1].toLowerCase();
        const name = `image${images.length}.${ext}`;
        const alt = node.getAttribute("alt");
        const title = node.getAttribute("title");
        for (const attr of Array.from(node.attributes)) node.removeAttribute(attr.name);
        node.dataset.mdSrc = name;
        if (alt) node.setAttribute("alt", alt);
        if (title) node.setAttribute("title", title);
        images.push({ url: `file:///fastra-html-clipboard/${name}`, base64: match[2] });
        continue;
      }
      if (node.tagName === "META" || node.tagName === "TITLE") {
        node.remove();
        continue;
      }
      if (!ALLOWED_CLIPBOARD_TAGS.has(node.tagName)) {
        return { ok: false, reason: node.tagName === "IMG" ? "images" : "format" };
      }
      if (node.hasAttribute("href")) {
        const href = clipboardURL(node.getAttribute("href"), /^(?:https?:\/\/|#)/i);
        if (href === null) return { ok: false, reason: "url" };
        node.setAttribute("href", href);
      }
      const styles = inlineClipboardStyles(node);
      for (const attr of Array.from(node.attributes)) {
        const permitted = node.tagName === "A" && (attr.name === "href" || attr.name === "title") || node.tagName === "OL" && attr.name === "start" || (node.tagName === "TH" || node.tagName === "TD") && (attr.name === "align" || attr.name === "colspan" || attr.name === "rowspan");
        if (!permitted) node.removeAttribute(attr.name);
      }
      if (node.tagName === "SPAN" || node.tagName === "FONT") {
        replaceStyledInline(node, styles, ownerDocument);
      }
    }
    return { ok: true, html: template.innerHTML, images };
  }

  // src/serializer.js
  function escapeAttrValue(v) {
    return String(v || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function randomToken(prefix) {
    if (typeof crypto !== "undefined" && crypto.getRandomValues) {
      return prefix + Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(16)).join("") + "END";
    }
    return prefix + Math.random().toString(16).slice(2) + Math.random().toString(16).slice(2) + "END";
  }
  function makeProtector(opaqueSources) {
    const sources = [];
    let namespace = randomToken("FASTRARICHSOURCE");
    const existing = Object.values(opaqueSources || {}).join("\0");
    for (let attempt = 0; existing.includes(namespace) && attempt < 16; attempt++) {
      namespace = randomToken("FASTRARICHSOURCE");
    }
    return {
      protect(source) {
        const token = `${namespace}${sources.length}END`;
        sources.push(source);
        return token;
      },
      restore(text) {
        if (!sources.length) return text;
        return text.replace(new RegExp(`${namespace}(\\d+)END`, "g"), (tok, idx) => sources[Number(idx)] ?? tok);
      }
    };
  }
  function escapePlainSegment(segment, { atBlockStart: atBlockStart2 = false, tableCell = false } = {}) {
    let out = segment.replace(/\\/g, "\\\\").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\*/g, "\\*").replace(/_/g, "\\_").replace(/`/g, "\\`").replace(/\[/g, "\\[").replace(/\]/g, "\\]").replace(/\b(https?)(?=:\/\/):/gi, "$1\\:").replace(/\b(www)\./gi, "$1\\.").replace(new RegExp("[$~]|(?<!\\\\)=(?==)|(?<==)=", "g"), "\\$&");
    if (atBlockStart2) {
      out = out.replace(/^([ \t]{0,3})(#{1,6})(?=\s|$)/, "$1\\$2").replace(/^([ \t]{0,3})>/, "$1\\>").replace(/^([ \t]*[-+*])(\s|$)/, (_, m, ws) => m.replace(/([-+*])$/, "\\$1") + ws).replace(/^([ \t]{0,3})(-)(?=(?:[ \t]*[-:|])+[ \t]*$)/, "$1\\$2").replace(/^([ \t]{0,3})(-)(?=[ \t]*\|)/, "$1\\$2").replace(/^([ \t]{0,3})(=+)(?=[ \t]*$)/, "$1\\$2").replace(/^([ \t]{0,3})(\d{1,9})([.)])(?=\s|$)/, "$1$2\\$3").replace(/^(?: {4}| {0,3}\t)(?=\S)/, (m) => (m[0] === "	" ? "&#9;" : "&#32;") + m.slice(1));
    }
    if (tableCell) {
      out = out.replace(/\|/g, "\\|").replace(/ {2,}/g, (s) => "&#32;".repeat(s.length));
    }
    return out;
  }
  function escapeMarkdownText(text, { atBlockStart: atBlockStart2 = false, tableCell = false } = {}) {
    const clean = String(text || "").replace(/\u200b/g, "");
    if (!clean) return "";
    if (!clean.includes("\xA0")) {
      return escapePlainSegment(clean, { atBlockStart: atBlockStart2, tableCell });
    }
    const parts = clean.split(/(\u00a0+)/);
    return parts.map((part, idx) => {
      if (!part) return "";
      if (part.startsWith("\xA0")) return "&nbsp;".repeat(part.length);
      return escapePlainSegment(part, { atBlockStart: atBlockStart2 && idx === 0, tableCell });
    }).join("");
  }
  function escapeHTMLText(text) {
    return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function markKey(mark) {
    return `${mark.type.name}:${JSON.stringify(mark.attrs)}`;
  }
  var MARK_ORDER = {
    link: 1,
    html_u: 2,
    html_ins: 2,
    html_small: 2,
    html_sub: 2,
    html_sup: 2,
    html_kbd: 2,
    html_samp: 2,
    html_var: 2,
    html_q: 2,
    html_cite: 2,
    html_abbr: 2,
    html_dfn: 2,
    strong: 3,
    em: 4,
    strike: 5,
    highlight: 6,
    code: 7
  };
  function sortMarks(marks2) {
    return [...marks2].sort((a, b) => (MARK_ORDER[a.type.name] || 10) - (MARK_ORDER[b.type.name] || 10));
  }
  function isPunctuation(c) {
    return !!c && /[\p{P}\p{S}]/u.test(c);
  }
  function isSpaceOrEmpty(c) {
    return !c || /\s/u.test(c);
  }
  function wrapDelimiterMark(rawInner, tag, delimiter, prevChar, nextChar, prevMarks, nextMarks, familyNames) {
    if (!rawInner) return "";
    const lead = rawInner.match(/^\s+/)?.[0] || "";
    const trail = rawInner.match(/\s+$/)?.[0] || "";
    const inner = rawInner.slice(lead.length, rawInner.length - trail.length);
    if (!inner) return rawInner;
    const effectivePrev = lead ? Array.from(lead).at(-1) : prevChar;
    const effectiveNext = trail ? Array.from(trail)[0] : nextChar;
    const effectivePrevMarks = lead ? [] : prevMarks;
    const effectiveNextMarks = trail ? [] : nextMarks;
    const edge = delimiter[0] === "*" ? inner.replace(/^\*+|\*+$/g, "") : inner;
    const chars = Array.from(edge);
    const first = chars[0] || "";
    const last = chars.at(-1) || "";
    const touchesNeighbor = (marks2, ch) => !isSpaceOrEmpty(ch) && marks2.some((m) => familyNames.includes(m.type.name));
    const joined = touchesNeighbor(effectivePrevMarks, effectivePrev) || touchesNeighbor(effectiveNextMarks, effectiveNext) || delimiter === "==" && [effectivePrev, effectiveNext, first, last].includes("=");
    const unsafe = joined || isPunctuation(first) && !isSpaceOrEmpty(effectivePrev) && !isPunctuation(effectivePrev) || isPunctuation(last) && !isSpaceOrEmpty(effectiveNext) && !isPunctuation(effectiveNext);
    const wrapped = unsafe ? `<${tag}>${inner}</${tag}>` : `${delimiter}${inner}${delimiter}`;
    return `${lead}${wrapped}${trail}`;
  }
  function extractInlineRuns(fragment) {
    const runs = [];
    fragment.forEach((node) => {
      runs.push(node);
    });
    return runs;
  }
  function firstCharOfNode(node) {
    if (!node) return "";
    if (node.isText) return Array.from(node.text.replace(/\u200b/g, ""))[0] || "";
    if (node.type.name === "image" || node.type.name === "math_inline" || node.type.name === "opaque_inline") return "\uFFFC";
    return "";
  }
  function lastCharOfNode(node) {
    if (!node) return "";
    if (node.isText) return Array.from(node.text.replace(/\u200b/g, "")).at(-1) || "";
    if (node.type.name === "image" || node.type.name === "math_inline" || node.type.name === "opaque_inline") return "\uFFFC";
    return "";
  }
  function serializeCodeSpan(rawText, { tableCell = false } = {}) {
    const clean = String(rawText || "").replace(/\u200b/g, "");
    const lines = clean.split(/\r\n?|\n/);
    return lines.map((part) => {
      if (!part) return "";
      const runs = part.match(/`+/g) || [];
      const fenceLen = runs.length ? Math.max(...runs.map((r) => r.length)) + 1 : 1;
      const fence = "`".repeat(fenceLen);
      const needsPad = /^`/.test(part) || /`$/.test(part) || /^ /.test(part) && / $/.test(part) && /[^ ]/.test(part);
      let out = needsPad ? `${fence} ${part} ${fence}` : `${fence}${part}${fence}`;
      if (tableCell) out = out.replace(/\|/g, "\\|");
      return out;
    }).join(tableCell ? "<br>" : "  \n");
  }
  function escapeTablePipes(text) {
    return text.replace(/\|/g, "\\|");
  }
  function escapeUnescapedTablePipes(text) {
    return text.replace(new RegExp("(?<!\\\\)(?:\\\\\\\\)*\\|", "g"), "\\$&");
  }
  function formatLinkDestination(rawHref, tableCell = false, wrap2 = false) {
    let href = String(rawHref || "");
    if (!href) return "";
    if (tableCell) href = escapeTablePipes(href).replace(/\r/g, "%0D").replace(/\n/g, "%0A");
    href = href.replace(/&/g, "&amp;");
    if (wrap2 || /[\s()<>[\]\u0000-\u001f]/.test(href)) {
      return `<${href.replace(/</g, "%3C").replace(/>/g, "%3E")}>`;
    }
    return href;
  }
  function formatLinkTitle(rawTitle, tableCell = false) {
    if (rawTitle == null || rawTitle === "") return "";
    let escaped = String(rawTitle).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/&/g, "&amp;");
    if (tableCell) escaped = escapeTablePipes(escaped).replace(/\r/g, "&#13;").replace(/\n/g, "&#10;");
    return ` "${escaped}"`;
  }
  function serializeInline(fragment, { opaqueSources = {}, protect = null, tableCell = false, inHeading = false } = {}) {
    const children = extractInlineRuns(fragment);
    if (!children.length) return "";
    const consecutiveBreaks = /* @__PURE__ */ new Set();
    for (let idx = 0; idx < children.length; idx++) {
      if (children[idx].type.name === "hard_break") {
        let runEnd = idx + 1;
        while (runEnd < children.length && children[runEnd].type.name === "hard_break") runEnd++;
        if (runEnd - idx > 1) {
          for (let k = idx; k < runEnd; k++) consecutiveBreaks.add(children[k]);
        }
        idx = runEnd - 1;
      }
    }
    function renderSlice(nodes2, activeMarkKeys, atBlockStart2) {
      let out = "";
      let i = 0;
      while (i < nodes2.length) {
        const node = nodes2[i];
        const sorted = sortMarks(node.marks || []).filter((m) => !activeMarkKeys.has(markKey(m)));
        if (sorted.length > 0) {
          const outer = sorted[0];
          const key = markKey(outer);
          const matchFn = (m) => markKey(m) === key;
          let j = i + 1;
          while (j < nodes2.length && nodes2[j].marks.some(matchFn)) j++;
          const subNodes = nodes2.slice(i, j);
          const nextActive = new Set(activeMarkKeys);
          nextActive.add(key);
          if (outer.type.name === "code") {
            let parts = [];
            const flushCodeParts = () => {
              if (!parts.length) return;
              out += serializeCodeSpan(parts.join(""), { tableCell });
              parts = [];
            };
            for (const sn of subNodes) {
              if (sn.isText) parts.push(sn.text);
              else if (sn.type.name === "hard_break") parts.push("\n");
              else {
                flushCodeParts();
                out += renderLeafInline(sn, atBlockStart2 && i === 0 && !out || out.endsWith("\n"));
              }
            }
            flushCodeParts();
          } else {
            const inner = renderSlice(subNodes, nextActive, false);
            const prevNode = i > 0 ? nodes2[i - 1] : null;
            const nextNode = j < nodes2.length ? nodes2[j] : null;
            const prevChar = lastCharOfNode(prevNode);
            const nextChar = firstCharOfNode(nextNode);
            const prevMarks = (prevNode?.marks || []).filter((m) => !activeMarkKeys.has(markKey(m)));
            const nextMarks = (nextNode?.marks || []).filter((m) => !activeMarkKeys.has(markKey(m)));
            if (outer.type.name === "strong") {
              out += wrapDelimiterMark(inner, "strong", "**", prevChar, nextChar, prevMarks, nextMarks, ["strong", "em"]);
            } else if (outer.type.name === "em") {
              out += wrapDelimiterMark(inner, "em", "*", prevChar, nextChar, prevMarks, nextMarks, ["strong", "em"]);
            } else if (outer.type.name === "highlight") {
              out += wrapDelimiterMark(inner, "mark", "==", prevChar, nextChar, prevMarks, nextMarks, ["highlight"]);
            } else if (outer.type.name === "strike") {
              out += wrapDelimiterMark(inner, "del", "~~", prevChar, nextChar, prevMarks, nextMarks, ["strike"]);
            } else if (outer.type.name === "link") {
              const dest = formatLinkDestination(outer.attrs.href, tableCell);
              const title = formatLinkTitle(outer.attrs.title, tableCell);
              out += `[${inner}](${dest}${title})`;
            } else if (outer.type.name.startsWith("html_")) {
              const tag = outer.type.name.slice(5);
              const attrs = ["title", "dir", "lang"].filter((a) => outer.attrs[a] != null && outer.attrs[a] !== "").map((a) => ` ${a}="${escapeAttrValue(outer.attrs[a])}"`).join("");
              out += `<${tag}${tableCell ? escapeTablePipes(attrs) : attrs}>${inner}</${tag}>`;
            } else {
              out += inner;
            }
          }
          i = j;
          continue;
        }
        out += renderLeafInline(node, atBlockStart2 && i === 0 || out.endsWith("\n"));
        i++;
      }
      return out;
    }
    function renderLeafInline(node, isStart) {
      if (node.isText) {
        return escapeMarkdownText(node.text, { atBlockStart: isStart, tableCell });
      }
      if (node.type.name === "hard_break") {
        return tableCell || inHeading || consecutiveBreaks.has(node) ? "<br>" : "  \n";
      }
      if (node.type.name === "image") {
        const mdSrc = node.attrs.mdSrc ?? node.attrs.src ?? "";
        if (!mdSrc) return "";
        let alt = String(node.attrs.alt || "").replace(/[\\[\]]/g, "\\$&").replace(/&/g, "&amp;");
        if (tableCell) alt = escapeTablePipes(alt).replace(/\r\n?|\n/g, "&#32;");
        const wrappedSrc = formatLinkDestination(mdSrc, tableCell, true);
        const title = formatLinkTitle(node.attrs.title, tableCell);
        return `![${alt}](${wrappedSrc}${title})`;
      }
      if (node.type.name === "math_inline") {
        if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === "string") {
          const source = opaqueSources[node.attrs.mathSourceKey];
          const src = tableCell ? escapeUnescapedTablePipes(source) : source;
          return protect ? protect(src) : src;
        }
        const tex = node.attrs.tex || "";
        return `$${tableCell ? escapeUnescapedTablePipes(tex) : tex}$`;
      }
      if (node.type.name === "opaque_inline") {
        if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === "string") {
          const src = opaqueSources[node.attrs.mathSourceKey];
          return protect ? protect(src) : src;
        }
        const raw = opaqueSources[node.attrs.opaqueKey] || "";
        const val = tableCell ? raw.replace(/\|/g, "\\|") : raw;
        return val && protect ? protect(val) : val;
      }
      return "";
    }
    return renderSlice(children, /* @__PURE__ */ new Set(), true);
  }
  function serializeCellInnerHTML(cellNode, opaqueSources, protect) {
    let out = "";
    cellNode.content.forEach((child) => {
      let chunk = "";
      if (child.isText) {
        chunk = escapeHTMLText(child.text.replace(/\u200b/g, ""));
      } else if (child.type.name === "hard_break") {
        chunk = "<br>";
      } else if (child.type.name === "image") {
        const src = escapeAttrValue(child.attrs.mdSrc ?? child.attrs.src ?? "");
        const alt = child.attrs.alt ? ` alt="${escapeAttrValue(child.attrs.alt)}"` : "";
        const title = child.attrs.title ? ` title="${escapeAttrValue(child.attrs.title)}"` : "";
        chunk = `<img src="${src}"${alt}${title}>`;
      } else if (child.type.name === "math_inline") {
        const src = child.attrs.mathSourceKey && typeof opaqueSources[child.attrs.mathSourceKey] === "string" ? opaqueSources[child.attrs.mathSourceKey] : `$${child.attrs.tex || ""}$`;
        chunk = protect ? protect(src) : src;
      } else if (child.type.name === "opaque_inline") {
        const src = child.attrs.mathSourceKey && typeof opaqueSources[child.attrs.mathSourceKey] === "string" ? opaqueSources[child.attrs.mathSourceKey] : opaqueSources[child.attrs.opaqueKey] || "";
        chunk = src && protect ? protect(src) : src;
      }
      for (const m of [...child.marks || []].reverse()) {
        if (m.type.name === "strong") chunk = `<strong>${chunk}</strong>`;
        else if (m.type.name === "em") chunk = `<em>${chunk}</em>`;
        else if (m.type.name === "code") chunk = `<code>${chunk}</code>`;
        else if (m.type.name === "highlight") chunk = `<mark>${chunk}</mark>`;
        else if (m.type.name === "strike") chunk = `<del>${chunk}</del>`;
        else if (m.type.name === "link") {
          const href = escapeAttrValue(m.attrs.href || "");
          const title = m.attrs.title ? ` title="${escapeAttrValue(m.attrs.title)}"` : "";
          chunk = `<a href="${href}"${title}>${chunk}</a>`;
        } else if (m.type.name.startsWith("html_")) {
          const tag = m.type.name.slice(5);
          const attrs = ["title", "dir", "lang"].filter((a) => m.attrs[a] != null && m.attrs[a] !== "").map((a) => ` ${a}="${escapeAttrValue(m.attrs[a])}"`).join("");
          chunk = `<${tag}${attrs}>${chunk}</${tag}>`;
        }
      }
      out += chunk;
    });
    return out;
  }
  function serializeHTMLTable(tableNode, opaqueSources, protect) {
    const rowsHTML = [];
    const headRows = [];
    const bodyRows = [];
    tableNode.content.forEach((row) => {
      const cells = [];
      let isHeaderRow = true;
      row.content.forEach((cell) => {
        const isTH = cell.type.name === "table_header";
        if (!isTH) isHeaderRow = false;
        const tag = isTH ? "th" : "td";
        const attrs = [];
        if (cell.attrs.align) attrs.push(` align="${escapeAttrValue(cell.attrs.align)}"`);
        if (cell.attrs.colspan > 1) attrs.push(` colspan="${cell.attrs.colspan}"`);
        if (cell.attrs.rowspan > 1) attrs.push(` rowspan="${cell.attrs.rowspan}"`);
        const cellWithMarks = serializeCellInnerHTML(cell, opaqueSources, protect);
        cells.push(`<${tag}${attrs.join("")}>${cellWithMarks}</${tag}>`);
      });
      const tr = `<tr>${cells.join("")}</tr>`;
      if (isHeaderRow && bodyRows.length === 0) headRows.push(tr);
      else bodyRows.push(tr);
    });
    if (headRows.length) rowsHTML.push(`<thead>${headRows.join("")}</thead>`);
    if (bodyRows.length) rowsHTML.push(`<tbody>${bodyRows.join("")}</tbody>`);
    return `<table>${rowsHTML.join("")}</table>`;
  }
  function serializeTable(tableNode, opaqueSources, protect) {
    let hasMerged = !tableNode.attrs.gfm;
    tableNode.content.forEach((row) => {
      row.content.forEach((cell) => {
        if (cell.attrs.colspan > 1 || cell.attrs.rowspan > 1) hasMerged = true;
      });
    });
    if (hasMerged) {
      return serializeHTMLTable(tableNode, opaqueSources, protect);
    }
    const rows = [];
    tableNode.content.forEach((row) => rows.push(row));
    if (!rows.length) return "";
    const width = Math.max(1, ...rows.map((r) => r.childCount));
    const lines = rows.map((row) => {
      const renderedCells = [];
      for (let i = 0; i < width; i++) {
        const cell = i < row.childCount ? row.child(i) : null;
        if (!cell) {
          renderedCells.push("");
          continue;
        }
        const val = serializeInline(cell.content, { opaqueSources, protect, tableCell: true }).replace(/\r\n?|\n/g, "<br>").replace(/^ +| +$/g, (s) => "&#32;".repeat(s.length));
        renderedCells.push(val);
      }
      return `| ${renderedCells.join(" | ")} |`;
    });
    const firstRowHasTH = [];
    rows[0].content.forEach((c) => firstRowHasTH.push(c.type.name === "table_header"));
    if (!firstRowHasTH.some(Boolean)) {
      lines.unshift(`| ${Array(width).fill(" ").join(" | ")} |`);
    }
    const sepCells = Array.from({ length: width }, (_, i) => {
      const align = i < rows[0].childCount ? rows[0].child(i).attrs.align : null;
      if (align === "center") return ":---:";
      if (align === "right") return "---:";
      if (align === "left") return ":---";
      return "---";
    });
    lines.splice(1, 0, `| ${sepCells.join(" | ")} |`);
    return lines.join("\n");
  }
  function updateListState(state, node, verbatimSource = null) {
    if (!state) return;
    if (node?.type?.name === "ordered_list") {
      state.kind = "ordered";
      if (verbatimSource != null) {
        const m = verbatimSource.match(/^\s*\d{1,9}([.)])/m);
        if (m) state.orderedDelimiter = m[1];
      }
      return;
    }
    if (node?.type?.name === "bullet_list") {
      state.kind = "bullet";
      if (verbatimSource != null) {
        const m = verbatimSource.match(/^\s*([-+*])(?:\s|$)/m);
        if (m) state.bulletMarker = m[1];
      }
      return;
    }
    state.kind = null;
  }
  function chooseListFormatting(state, node) {
    if (!state) return { orderedDelimiter: ".", bulletMarker: "-" };
    if (node.type.name === "ordered_list") {
      const orderedDelimiter = state.kind === "ordered" && state.orderedDelimiter === "." ? ")" : ".";
      state.kind = "ordered";
      state.orderedDelimiter = orderedDelimiter;
      return { orderedDelimiter, bulletMarker: "-" };
    }
    if (node.type.name === "bullet_list") {
      const bulletMarker = state.kind === "bullet" && state.bulletMarker === "-" ? "*" : "-";
      state.kind = "bullet";
      state.bulletMarker = bulletMarker;
      return { orderedDelimiter: ".", bulletMarker };
    }
    state.kind = null;
    return { orderedDelimiter: ".", bulletMarker: "-" };
  }
  function serializeBlockNode(node, { opaqueSources = {}, protect = null, insideContainer = false, orderedDelimiter = ".", bulletMarker = "-" } = {}) {
    switch (node.type.name) {
      case "blank_line":
        return node.content.size > 0 ? serializeInline(node.content, { opaqueSources, protect }) : "  ";
      case "paragraph": {
        const items = extractInlineRuns(node.content);
        let trailingBreaks = 0;
        while (items.length && items.at(-1).type.name === "hard_break") {
          items.pop();
          trailingBreaks++;
        }
        if (!insideContainer && trailingBreaks >= 1) {
          const mainText = items.length ? serializeInline({ forEach: (fn) => items.forEach((n, i) => fn(n, i)) }, { opaqueSources, protect }) : "";
          const blanks = Array(trailingBreaks).fill("  ").join("\n\n");
          return mainText ? `${mainText}

${blanks}` : blanks;
        }
        if (insideContainer) {
          if (!items.length && trailingBreaks === 0) {
            return insideContainer === "blockquote" || insideContainer === "list_item_multi" ? "  " : "";
          }
          const mainText = items.length ? serializeInline({ forEach: (fn) => items.forEach((n, i) => fn(n, i)) }, { opaqueSources, protect }) : "";
          return trailingBreaks > 0 ? `${mainText}${"<br>".repeat(trailingBreaks)}` : mainText;
        }
        return items.length ? serializeInline({ forEach: (fn) => items.forEach((n, i) => fn(n, i)) }, { opaqueSources, protect }) : "";
      }
      case "heading": {
        const hashes = "#".repeat(Math.min(6, Math.max(1, node.attrs.level || 1)));
        const text = serializeInline(node.content, { opaqueSources, protect, inHeading: true }).replace(/(^|[ \t])(#+)(?=[ \t]*$)/, "$1\\$2");
        return text ? `${hashes} ${text}` : `${hashes} `;
      }
      case "horizontal_rule":
        return "---";
      case "code_block": {
        const raw = node.textContent.replace(/\n$/, "");
        const runs = raw.match(/`+/g) || [];
        const fence = "`".repeat(Math.max(3, ...runs.map((r) => r.length + 1)));
        const lang = node.attrs.language || "";
        return `${fence}${lang}
${raw}
${fence}`;
      }
      case "blockquote": {
        const childStrings = [];
        const childListState = { kind: null, orderedDelimiter: ".", bulletMarker: "-" };
        node.content.forEach((child) => {
          const listStyle = chooseListFormatting(childListState, child);
          childStrings.push(serializeBlockNode(child, { opaqueSources, protect, insideContainer: "blockquote", ...listStyle }));
        });
        const joined = childStrings.join("\n\n");
        return joined.split("\n").map((line) => line ? `> ${line}` : ">").join("\n");
      }
      case "bullet_list":
      case "ordered_list": {
        const isOrdered = node.type.name === "ordered_list";
        const start = isOrdered ? Math.max(0, Number(node.attrs.order ?? 1)) : 1;
        let isLoose = !node.attrs.tight;
        node.content.forEach((item) => {
          item.content.forEach((child, _, index) => {
            if (index > 0 && child.type.name === "paragraph" && item.child(index - 1).type.name === "paragraph") {
              isLoose = true;
            }
          });
        });
        const renderedItems = [];
        node.content.forEach((item, _offset, index) => {
          const marker = isOrdered ? `${start + index}${orderedDelimiter} ` : `${bulletMarker} `;
          const taskPrefix = item.attrs.task !== null ? item.attrs.task ? "[x] " : "[ ] " : "";
          const pad = " ".repeat(marker.length);
          const childParts = [];
          const childListState = { kind: null, orderedDelimiter: ".", bulletMarker: "-" };
          item.content.forEach((child, _cOffset, cIdx) => {
            const listStyle = chooseListFormatting(childListState, child);
            const text = serializeBlockNode(child, {
              opaqueSources,
              protect,
              insideContainer: item.childCount > 1 ? "list_item_multi" : "list_item",
              ...listStyle
            });
            const prefix = cIdx === 0 ? taskPrefix : "";
            const prefixed = prefix + text;
            const lines = prefixed.split("\n");
            childParts.push(
              lines.map((line, lIdx) => cIdx === 0 && lIdx === 0 ? marker + line : line ? pad + line : "").join("\n")
            );
          });
          renderedItems.push(childParts.join(isLoose ? "\n\n" : "\n"));
        });
        return renderedItems.join(isLoose ? "\n\n" : "\n");
      }
      case "table":
        return serializeTable(node, opaqueSources, protect);
      case "math_block": {
        if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === "string") {
          const src = opaqueSources[node.attrs.mathSourceKey];
          return protect ? protect(src) : src;
        }
        return `$$
${node.attrs.tex || ""}
$$`;
      }
      case "opaque_block": {
        if (node.attrs.mathSourceKey && typeof opaqueSources[node.attrs.mathSourceKey] === "string") {
          const src2 = opaqueSources[node.attrs.mathSourceKey];
          return protect ? protect(src2) : src2;
        }
        const src = opaqueSources[node.attrs.opaqueKey] || "";
        return src && protect ? protect(src) : src;
      }
      default:
        return "";
    }
  }
  function findImageEnding(node) {
    let found2 = null;
    node.descendants((child) => {
      if (!found2 && child.type.name === "image" && child.attrs.imageEnding) {
        found2 = child.attrs.imageEnding === "crlf" ? "\r\n" : "\r";
        return false;
      }
      return true;
    });
    return found2;
  }
  function serializeDocument(doc3, {
    contexts,
    originals,
    opaqueSources = {},
    lastInputType = ""
  } = {}) {
    const isSingleEmptyParagraph = doc3.childCount === 1 && doc3.firstChild.type.name === "paragraph" && doc3.firstChild.content.size === 0;
    const emptyDocPlaceholder = isSingleEmptyParagraph && !!doc3.firstChild.attrs.mdEmpty;
    const deletedPlaceholder = isSingleEmptyParagraph && !doc3.firstChild.attrs.mdEmpty;
    let contextKey = doc3.attrs.sourceContext || "";
    if (!contextKey) {
      for (let i = 0; i < doc3.childCount; i++) {
        const child = doc3.child(i);
        if (child.attrs?.mdBlockId != null && child.attrs.mdContext) {
          contextKey = child.attrs.mdContext;
          break;
        }
      }
    }
    const ctx = contexts?.get(contextKey) || contexts?.get("") || {
      blocks: [],
      hiddenPrefixes: /* @__PURE__ */ new Map(),
      trailingHidden: /* @__PURE__ */ new Set(),
      trailingOwner: null
    };
    if (emptyDocPlaceholder) {
      return (ctx.blocks || []).filter((b) => b.hidden).map((b) => b.source).join("");
    }
    if (deletedPlaceholder) {
      return (ctx.blocks || []).filter((b) => b.hidden && b.source.trim()).map((b) => b.source).join("");
    }
    const protector = makeProtector(opaqueSources);
    const usedOrigins = /* @__PURE__ */ new Set();
    const emittedHidden = /* @__PURE__ */ new Set();
    const topNodes = [];
    doc3.content.forEach((child) => topNodes.push(child));
    const singleOriginCounts = /* @__PURE__ */ new Map();
    for (const n of topNodes) {
      if (n.attrs?.mdBlockId != null && Number(n.attrs?.mdBlockTotal || 1) === 1) {
        const k = `${n.attrs.mdContext || ""}${n.attrs.mdBlockId}`;
        singleOriginCounts.set(k, (singleOriginCounts.get(k) || 0) + 1);
      }
    }
    let output = "";
    let prevBlockWasVerbatim = true;
    const listState = { kind: null, orderedDelimiter: ".", bulletMarker: "-" };
    function lineEndingCount(text) {
      let count = 0;
      for (let index = text.length - 1; index >= 0 && count < 2; index--) {
        if (text[index] !== "\r" && text[index] !== "\n") break;
        if (text[index] === "\n" && text[index - 1] === "\r") index--;
        count++;
      }
      return count;
    }
    function separateBlocks(ending) {
      if (output) output += ending.repeat(Math.max(0, 2 - lineEndingCount(output)));
    }
    function emitHiddenForBlock(fullId, { allowLeadingWhitespace = false } = {}) {
      if (!fullId || emittedHidden.has(fullId)) return;
      emittedHidden.add(fullId);
      for (const h of ctx.hiddenPrefixes?.get(fullId) || []) {
        emittedHidden.add("hidden:" + h.id);
        if (!h.source.trim()) {
          if (!output && !allowLeadingWhitespace) continue;
          if (!prevBlockWasVerbatim && lineEndingCount(output) >= 2) continue;
        } else {
          listState.kind = null;
        }
        output += h.source;
      }
    }
    function collectBlockOrigins(target, out = []) {
      if (target.attrs?.mdBlockId != null) {
        out.push(`${target.attrs.mdContext || ""}${target.attrs.mdBlockId}`);
      }
      target.content?.forEach((child) => {
        if (child.isBlock) collectBlockOrigins(child, out);
      });
      return out;
    }
    const docEnding = (ctx.blocks || []).some((b) => b.source?.includes("\r\n")) ? "\r\n" : (ctx.blocks || []).some((b) => b.source?.includes("\r")) ? "\r" : "\n";
    const firstVisible = ctx.blocks?.find((block) => !block.hidden);
    if (firstVisible) {
      const firstTop = topNodes[0];
      const firstTopId = firstTop?.attrs?.mdBlockId != null ? `${firstTop.attrs.mdContext || ""}${firstTop.attrs.mdBlockId}` : null;
      emitHiddenForBlock(firstVisible.id, { allowLeadingWhitespace: firstTopId === firstVisible.id });
    }
    let idx = 0;
    while (idx < topNodes.length) {
      const node = topNodes[idx];
      const mdCtx = node.attrs?.mdContext || "";
      const mdBlockId = node.attrs?.mdBlockId || null;
      const total = Math.max(1, Number(node.attrs?.mdBlockTotal || 1));
      const sub = Number(node.attrs?.mdBlockSub || 0);
      const fullId = mdBlockId != null ? `${mdCtx}${mdBlockId}` : null;
      const original = fullId != null ? originals?.get(fullId) : null;
      const isSplitSingleOrigin = fullId != null && total === 1 && (singleOriginCounts.get(fullId) || 0) > 1;
      if (original && !isSplitSingleOrigin && !usedOrigins.has(fullId) && sub === 0 && idx + total <= topNodes.length) {
        const group = topNodes.slice(idx, idx + total);
        const completeOrder = group.every(
          (cand, k) => (cand.attrs?.mdContext || "") === mdCtx && cand.attrs?.mdBlockId === mdBlockId && Number(cand.attrs?.mdBlockSub || 0) === k && Number(cand.attrs?.mdBlockTotal || 1) === total
        );
        if (completeOrder) {
          const snap = JSON.stringify(group.map(canonicalNodeSnapshot));
          if (snap === original.canonicalSnapshot) {
            usedOrigins.add(fullId);
            emitHiddenForBlock(fullId);
            output += original.source;
            updateListState(listState, group.at(-1), original.source);
            prevBlockWasVerbatim = true;
            idx += total;
            continue;
          }
        }
      }
      for (const originId of collectBlockOrigins(node)) {
        if (!usedOrigins.has(originId)) {
          usedOrigins.add(originId);
          emitHiddenForBlock(originId);
        }
      }
      const sourceEnding = original?.source?.includes("\r\n") ? "\r\n" : original?.source?.includes("\r") ? "\r" : original?.source?.includes("\n") ? "\n" : docEnding;
      const imgEnding = findImageEnding(node);
      const ending = imgEnding || sourceEnding;
      if (idx > 0) separateBlocks(ending);
      if (original && sub === 0 && total > 1 && idx + total <= topNodes.length) {
        const group = topNodes.slice(idx, idx + total);
        const sameGroup = group.every(
          (cand, k) => (cand.attrs?.mdContext || "") === mdCtx && cand.attrs?.mdBlockId === mdBlockId && Number(cand.attrs?.mdBlockSub || 0) === k && Number(cand.attrs?.mdBlockTotal || 1) === total
        );
        if (sameGroup) {
          const rendered2 = group.map((n) => {
            if (n.type.name === "paragraph" && n.content.size === 0) return "  ";
            const listStyle2 = chooseListFormatting(listState, n);
            return serializeBlockNode(n, { opaqueSources, protect: protector.protect, ...listStyle2 });
          }).join("\n\n");
          let text2 = ending !== "\n" ? rendered2.replace(/\r\n?|\n/g, ending) : rendered2;
          text2 = protector.restore(text2);
          const rawTail2 = original.source.match(/[\r\n]*$/)?.[0] ?? "";
          const needsSeparator = idx + total < topNodes.length && lineEndingCount(rawTail2) < 2;
          const suffix = !needsSeparator && canonicalGroupStructure(group) === original.structure ? rawTail2 : ending + ending;
          output += text2 + suffix;
          prevBlockWasVerbatim = false;
          idx += total;
          continue;
        }
      }
      const isEmptyOrWhitespaceOnlyParagraph = node.type.name === "blank_line" && !node.content.size || node.type.name === "paragraph" && (node.content.size === 0 || node.textContent.replace(/[ \t]/g, "").length === 0 && (() => {
        let onlyPlainSpaces = true;
        node.content.forEach((ch) => {
          if (!ch.isText) onlyPlainSpaces = false;
        });
        return onlyPlainSpaces;
      })());
      if (isEmptyOrWhitespaceOnlyParagraph) {
        listState.kind = null;
        output += `  ${ending}${ending}`;
        prevBlockWasVerbatim = false;
        idx += 1;
        continue;
      }
      const listStyle = chooseListFormatting(listState, node);
      const rendered = serializeBlockNode(node, { opaqueSources, protect: protector.protect, ...listStyle });
      let text = ending !== "\n" ? rendered.replace(/\r\n?|\n/g, ending) : rendered;
      text = protector.restore(text);
      const hasNext = idx + 1 < topNodes.length;
      const rawTail = original?.source?.match(/[\r\n]*$/)?.[0] ?? "";
      const rawLineCount = lineEndingCount(rawTail);
      const safeTail = hasNext && rawLineCount < 2 ? ending + ending : rawTail;
      if (original && total === 1 && !isSplitSingleOrigin) {
        const suffix = canonicalGroupStructure([node]) === original.structure ? safeTail : ending + ending;
        output += text + suffix;
      } else if (isSplitSingleOrigin && !hasNext && original) {
        const tailSuffix = canonicalGroupStructure([node]) === original.structure ? rawTail : ending + ending;
        output += text + tailSuffix;
      } else {
        output += text ? `${text}${ending}${ending}` : ending;
      }
      prevBlockWasVerbatim = false;
      idx += 1;
    }
    for (const b of ctx.blocks || []) {
      if (b.hidden && !emittedHidden.has("hidden:" + b.id) && (b.source.trim() || ctx.trailingHidden?.has(b.id) && (ctx.trailingOwner === null || usedOrigins.has(ctx.trailingOwner)))) {
        if (b.source.trim() && (!prevBlockWasVerbatim || !ctx.trailingHidden?.has(b.id) || !usedOrigins.has(ctx.trailingOwner))) separateBlocks(docEnding);
        output += b.source;
      }
    }
    return output;
  }

  // src/nodeviews.js
  function applyImageNodeAttrs(img, node, imageUrlOverrides) {
    const mdSrc = node.attrs.mdSrc;
    const resolvedSrc = node.attrs.src && imageUrlOverrides.get(node.attrs.src) || node.attrs.src || mdSrc && imageUrlOverrides.get(mdSrc) || "";
    img.setAttribute("src", resolvedSrc);
    img.setAttribute("alt", node.attrs.alt || "");
    if (mdSrc != null) img.setAttribute("data-md-src", mdSrc);
    else img.removeAttribute("data-md-src");
    if (node.attrs.title != null && node.attrs.title !== "") img.setAttribute("title", node.attrs.title);
    else img.removeAttribute("title");
    if (node.attrs.width != null && node.attrs.width !== "") img.setAttribute("width", String(node.attrs.width));
    else img.removeAttribute("width");
    if (node.attrs.height != null && node.attrs.height !== "") img.setAttribute("height", String(node.attrs.height));
    else img.removeAttribute("height");
    if (node.attrs.imageTransaction) img.setAttribute("data-md-image-transaction", node.attrs.imageTransaction);
    else img.removeAttribute("data-md-image-transaction");
    if (node.attrs.imageEnding) img.setAttribute("data-md-image-ending", node.attrs.imageEnding);
    else img.removeAttribute("data-md-image-ending");
  }
  function setMathSource(dom, key) {
    if (key) dom.setAttribute("data-md-math-source", key);
    else dom.removeAttribute("data-md-math-source");
  }
  function mathNodeView(node, view) {
    let current = node;
    const document2 = view.dom.ownerDocument;
    const inline = node.isInline;
    const dom = document2.createElement(inline ? "span" : "div");
    dom.setAttribute("contenteditable", "false");
    function render(target) {
      const { tex, mathSourceKey, displayMode } = target.attrs;
      const display = !inline || !!displayMode;
      dom.className = display ? "math-block" : "math-inline";
      dom.setAttribute("data-tex", tex || "");
      setMathSource(dom, mathSourceKey);
      const katex = document2.defaultView?.katex;
      if (katex) {
        try {
          katex.render(tex || "", dom, { displayMode: display, throwOnError: false, trust: false });
          dom.setAttribute("data-rendered", "true");
          return;
        } catch (_) {
        }
      }
      dom.removeAttribute("data-rendered");
      dom.textContent = tex || "";
    }
    render(node);
    return {
      dom,
      update(updated) {
        if (updated.type !== current.type) return false;
        if (updated.attrs.tex !== current.attrs.tex || updated.attrs.mathSourceKey !== current.attrs.mathSourceKey || updated.attrs.displayMode !== current.attrs.displayMode) render(updated);
        current = updated;
        return true;
      },
      ignoreMutation() {
        return true;
      }
    };
  }
  function opaqueNodeView(node, view) {
    let current = node;
    const dom = view.dom.ownerDocument.createElement(node.attrs.tag || (node.isInline ? "span" : "section"));
    dom.setAttribute("contenteditable", "false");
    function render(target) {
      if (target.attrs.className) dom.className = target.attrs.className;
      else dom.removeAttribute("class");
      dom.setAttribute("data-md-opaque", target.attrs.opaqueKey || "");
      setMathSource(dom, target.attrs.mathSourceKey);
      const html = target.attrs.rawHTML || "";
      if (dom.innerHTML !== html) dom.innerHTML = html;
    }
    render(node);
    return {
      dom,
      update(updated) {
        if (updated.type !== current.type || updated.attrs.tag !== current.attrs.tag) return false;
        render(updated);
        current = updated;
        return true;
      },
      ignoreMutation() {
        return true;
      }
    };
  }
  function createNodeViews({
    getImageOverrides,
    isBlocked,
    onSelectImage,
    onToggleTask
  }) {
    return {
      list_item(node, view, getPos) {
        let current = node;
        const doc3 = view.dom.ownerDocument;
        const dom = doc3.createElement("li");
        const isInitialTask = node.attrs.task !== null;
        if (!isInitialTask) {
          return {
            dom,
            contentDOM: dom,
            update(updated) {
              if (updated.type !== current.type) return false;
              if (updated.attrs.task !== null) return false;
              current = updated;
              return true;
            },
            ignoreMutation(mutation) {
              return mutation.target === dom && mutation.type === "attributes";
            }
          };
        }
        const checkbox = doc3.createElement("input");
        checkbox.type = "checkbox";
        checkbox.contentEditable = "false";
        const contentDOM = doc3.createElement("div");
        contentDOM.className = "fastra-pm-li-content";
        function sync(target) {
          current = target;
          dom.setAttribute("data-task", target.attrs.task ? "checked" : "unchecked");
          checkbox.toggleAttribute("checked", !!target.attrs.task);
          checkbox.checked = !!target.attrs.task;
          if (checkbox.parentNode !== dom) dom.prepend(checkbox);
          dom.insertBefore(contentDOM, checkbox.nextSibling);
        }
        checkbox.addEventListener("mousedown", (e) => {
          e.preventDefault();
        });
        checkbox.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          if (isBlocked()) {
            checkbox.checked = !!current.attrs.task;
            return;
          }
          const pos = typeof getPos === "function" ? getPos() : null;
          if (pos == null || current.attrs.task === null) {
            checkbox.checked = !!current.attrs.task;
            return;
          }
          onToggleTask?.(pos, !current.attrs.task);
          queueMicrotask(() => {
            checkbox.checked = !!current.attrs.task;
          });
        });
        sync(node);
        return {
          dom,
          contentDOM,
          update(updated) {
            if (updated.type !== current.type) return false;
            if (updated.attrs.task === null) return false;
            sync(updated);
            return true;
          },
          ignoreMutation(mutation) {
            return mutation.target === checkbox || mutation.target === dom && mutation.type === "attributes";
          },
          stopEvent(event) {
            return event.target === checkbox;
          }
        };
      },
      image(node, view, getPos) {
        let current = node;
        const dom = view.dom.ownerDocument.createElement("img");
        applyImageNodeAttrs(dom, current, getImageOverrides());
        return {
          dom,
          update(updated) {
            if (updated.type !== current.type) return false;
            current = updated;
            applyImageNodeAttrs(dom, current, getImageOverrides());
            return true;
          },
          selectNode() {
            dom.setAttribute("data-md-selected-image", "");
            onSelectImage?.(dom, getPos);
          },
          deselectNode() {
            dom.removeAttribute("data-md-selected-image");
          },
          ignoreMutation() {
            return true;
          }
        };
      },
      math_block: mathNodeView,
      math_inline: mathNodeView,
      opaque_block: opaqueNodeView,
      opaque_inline: opaqueNodeView
    };
  }

  // node_modules/prosemirror-commands/dist/index.js
  var deleteSelection = (state, dispatch) => {
    if (state.selection.empty)
      return false;
    if (dispatch)
      dispatch(state.tr.deleteSelection().scrollIntoView());
    return true;
  };
  function atBlockStart(state, view) {
    let { $cursor } = state.selection;
    if (!$cursor || (view ? !view.endOfTextblock("backward", state) : $cursor.parentOffset > 0))
      return null;
    return $cursor;
  }
  var joinBackward = (state, dispatch, view) => {
    let $cursor = atBlockStart(state, view);
    if (!$cursor)
      return false;
    let $cut = findCutBefore($cursor);
    if (!$cut) {
      let range = $cursor.blockRange(), target = range && liftTarget(range);
      if (target == null)
        return false;
      if (dispatch)
        dispatch(state.tr.lift(range, target).scrollIntoView());
      return true;
    }
    let before = $cut.nodeBefore;
    if (deleteBarrier(state, $cut, dispatch, -1))
      return true;
    if ($cursor.parent.content.size == 0 && (textblockAt(before, "end") || NodeSelection.isSelectable(before))) {
      for (let depth = $cursor.depth; ; depth--) {
        let delStep = replaceStep(state.doc, $cursor.before(depth), $cursor.after(depth), Slice.empty);
        if (delStep && delStep.slice.size < delStep.to - delStep.from) {
          if (dispatch) {
            let tr = state.tr.step(delStep);
            tr.setSelection(textblockAt(before, "end") ? Selection.findFrom(tr.doc.resolve(tr.mapping.map($cut.pos, -1)), -1) : NodeSelection.create(tr.doc, $cut.pos - before.nodeSize));
            dispatch(tr.scrollIntoView());
          }
          return true;
        }
        if (depth == 1 || $cursor.node(depth - 1).childCount > 1)
          break;
      }
    }
    if (before.isAtom && $cut.depth == $cursor.depth - 1) {
      if (dispatch)
        dispatch(state.tr.delete($cut.pos - before.nodeSize, $cut.pos).scrollIntoView());
      return true;
    }
    return false;
  };
  function textblockAt(node, side, only = false) {
    for (let scan = node; scan; scan = side == "start" ? scan.firstChild : scan.lastChild) {
      if (scan.isTextblock)
        return true;
      if (only && scan.childCount != 1)
        return false;
    }
    return false;
  }
  var selectNodeBackward = (state, dispatch, view) => {
    let { $head, empty: empty2 } = state.selection, $cut = $head;
    if (!empty2)
      return false;
    if ($head.parent.isTextblock) {
      if (view ? !view.endOfTextblock("backward", state) : $head.parentOffset > 0)
        return false;
      $cut = findCutBefore($head);
    }
    let node = $cut && $cut.nodeBefore;
    if (!node || !NodeSelection.isSelectable(node))
      return false;
    if (dispatch)
      dispatch(state.tr.setSelection(NodeSelection.create(state.doc, $cut.pos - node.nodeSize)).scrollIntoView());
    return true;
  };
  function findCutBefore($pos) {
    if (!$pos.parent.type.spec.isolating)
      for (let i = $pos.depth - 1; i >= 0; i--) {
        if ($pos.index(i) > 0)
          return $pos.doc.resolve($pos.before(i + 1));
        if ($pos.node(i).type.spec.isolating)
          break;
      }
    return null;
  }
  function atBlockEnd(state, view) {
    let { $cursor } = state.selection;
    if (!$cursor || (view ? !view.endOfTextblock("forward", state) : $cursor.parentOffset < $cursor.parent.content.size))
      return null;
    return $cursor;
  }
  var joinForward = (state, dispatch, view) => {
    let $cursor = atBlockEnd(state, view);
    if (!$cursor)
      return false;
    let $cut = findCutAfter($cursor);
    if (!$cut)
      return false;
    let after = $cut.nodeAfter;
    if (deleteBarrier(state, $cut, dispatch, 1))
      return true;
    if ($cursor.parent.content.size == 0 && (textblockAt(after, "start") || NodeSelection.isSelectable(after))) {
      let delStep = replaceStep(state.doc, $cursor.before(), $cursor.after(), Slice.empty);
      if (delStep && delStep.slice.size < delStep.to - delStep.from) {
        if (dispatch) {
          let tr = state.tr.step(delStep);
          tr.setSelection(textblockAt(after, "start") ? Selection.findFrom(tr.doc.resolve(tr.mapping.map($cut.pos)), 1) : NodeSelection.create(tr.doc, tr.mapping.map($cut.pos)));
          dispatch(tr.scrollIntoView());
        }
        return true;
      }
    }
    if (after.isAtom && $cut.depth == $cursor.depth - 1) {
      if (dispatch)
        dispatch(state.tr.delete($cut.pos, $cut.pos + after.nodeSize).scrollIntoView());
      return true;
    }
    return false;
  };
  var selectNodeForward = (state, dispatch, view) => {
    let { $head, empty: empty2 } = state.selection, $cut = $head;
    if (!empty2)
      return false;
    if ($head.parent.isTextblock) {
      if (view ? !view.endOfTextblock("forward", state) : $head.parentOffset < $head.parent.content.size)
        return false;
      $cut = findCutAfter($head);
    }
    let node = $cut && $cut.nodeAfter;
    if (!node || !NodeSelection.isSelectable(node))
      return false;
    if (dispatch)
      dispatch(state.tr.setSelection(NodeSelection.create(state.doc, $cut.pos)).scrollIntoView());
    return true;
  };
  function findCutAfter($pos) {
    if (!$pos.parent.type.spec.isolating)
      for (let i = $pos.depth - 1; i >= 0; i--) {
        let parent = $pos.node(i);
        if ($pos.index(i) + 1 < parent.childCount)
          return $pos.doc.resolve($pos.after(i + 1));
        if (parent.type.spec.isolating)
          break;
      }
    return null;
  }
  var lift2 = (state, dispatch) => {
    let { $from, $to } = state.selection;
    let range = $from.blockRange($to), target = range && liftTarget(range);
    if (target == null)
      return false;
    if (dispatch)
      dispatch(state.tr.lift(range, target).scrollIntoView());
    return true;
  };
  var newlineInCode = (state, dispatch) => {
    let { $head, $anchor } = state.selection;
    if (!$head.parent.type.spec.code || !$head.sameParent($anchor))
      return false;
    if (dispatch)
      dispatch(state.tr.insertText("\n").scrollIntoView());
    return true;
  };
  function defaultBlockAt(match) {
    for (let i = 0; i < match.edgeCount; i++) {
      let { type } = match.edge(i);
      if (type.isTextblock && !type.hasRequiredAttrs())
        return type;
    }
    return null;
  }
  var exitCode = (state, dispatch) => {
    let { $head, $anchor } = state.selection;
    if (!$head.parent.type.spec.code || !$head.sameParent($anchor))
      return false;
    let above = $head.node(-1), after = $head.indexAfter(-1), type = defaultBlockAt(above.contentMatchAt(after));
    if (!type || !above.canReplaceWith(after, after, type))
      return false;
    if (dispatch) {
      let pos = $head.after(), tr = state.tr.replaceWith(pos, pos, type.createAndFill());
      tr.setSelection(Selection.near(tr.doc.resolve(pos), 1));
      dispatch(tr.scrollIntoView());
    }
    return true;
  };
  var createParagraphNear = (state, dispatch) => {
    let sel = state.selection, { $from, $to } = sel;
    if (sel instanceof AllSelection || $from.parent.inlineContent || $to.parent.inlineContent)
      return false;
    let type = defaultBlockAt($to.parent.contentMatchAt($to.indexAfter()));
    if (!type || !type.isTextblock)
      return false;
    if (dispatch) {
      let side = (!$from.parentOffset && $to.index() < $to.parent.childCount ? $from : $to).pos;
      let tr = state.tr.insert(side, type.createAndFill());
      tr.setSelection(TextSelection.create(tr.doc, side + 1));
      dispatch(tr.scrollIntoView());
    }
    return true;
  };
  var liftEmptyBlock = (state, dispatch) => {
    let { $cursor } = state.selection;
    if (!$cursor || $cursor.parent.content.size)
      return false;
    if ($cursor.depth > 1 && $cursor.after() != $cursor.end(-1)) {
      let before = $cursor.before();
      if (canSplit(state.doc, before)) {
        if (dispatch)
          dispatch(state.tr.split(before).scrollIntoView());
        return true;
      }
    }
    let range = $cursor.blockRange(), target = range && liftTarget(range);
    if (target == null)
      return false;
    if (dispatch)
      dispatch(state.tr.lift(range, target).scrollIntoView());
    return true;
  };
  function splitBlockAs(splitNode) {
    return (state, dispatch) => {
      if (state.selection instanceof NodeSelection && state.selection.node.isBlock) {
        let { $from: $from2 } = state.selection;
        if (!$from2.parentOffset || !canSplit(state.doc, $from2.pos))
          return false;
        if (dispatch)
          dispatch(state.tr.split($from2.pos).scrollIntoView());
        return true;
      }
      if (!state.selection.$from.depth)
        return false;
      let tr = state.tr;
      if (!state.selection.empty && (state.selection instanceof TextSelection || state.selection instanceof AllSelection))
        tr.deleteSelection();
      let { $from } = tr.selection, mapFrom = tr.steps.length;
      let types = [];
      let splitDepth, deflt, atEnd = false, atStart = false;
      for (let d = $from.depth; ; d--) {
        let node = $from.node(d);
        if (node.isBlock) {
          atEnd = $from.end(d) == $from.pos + ($from.depth - d);
          atStart = $from.start(d) == $from.pos - ($from.depth - d);
          deflt = defaultBlockAt($from.node(d - 1).contentMatchAt($from.indexAfter(d - 1)));
          let splitType = splitNode && splitNode($from.parent, atEnd, $from);
          types.unshift(splitType || (atEnd && deflt ? { type: deflt } : null));
          splitDepth = d;
          break;
        } else {
          if (d == 1)
            return false;
          types.unshift(null);
        }
      }
      let splitPos = $from.pos;
      let can = canSplit(tr.doc, splitPos, types.length, types);
      if (!can) {
        types[0] = deflt ? { type: deflt } : null;
        can = canSplit(tr.doc, splitPos, types.length, types);
      }
      if (!can)
        return false;
      tr.split(splitPos, types.length, types);
      if (!atEnd && atStart && $from.node(splitDepth).type != deflt) {
        let mapping = tr.mapping.slice(mapFrom);
        let first = mapping.map($from.before(splitDepth)), $first = tr.doc.resolve(first);
        if (deflt && $from.node(splitDepth - 1).canReplaceWith($first.index(), $first.index() + 1, deflt))
          tr.setNodeMarkup(mapping.map($from.before(splitDepth)), deflt);
      }
      if (dispatch)
        dispatch(tr.scrollIntoView());
      return true;
    };
  }
  var splitBlock = splitBlockAs();
  var selectAll = (state, dispatch) => {
    if (dispatch)
      dispatch(state.tr.setSelection(new AllSelection(state.doc)));
    return true;
  };
  function joinMaybeClear(state, $pos, dispatch) {
    let before = $pos.nodeBefore, after = $pos.nodeAfter, index = $pos.index();
    if (!before || !after || !before.type.compatibleContent(after.type))
      return false;
    if (!before.content.size && $pos.parent.canReplace(index - 1, index)) {
      if (dispatch)
        dispatch(state.tr.delete($pos.pos - before.nodeSize, $pos.pos).scrollIntoView());
      return true;
    }
    if (!$pos.parent.canReplace(index, index + 1) || !(after.isTextblock || canJoin(state.doc, $pos.pos)))
      return false;
    if (dispatch)
      dispatch(state.tr.join($pos.pos).scrollIntoView());
    return true;
  }
  function deleteBarrier(state, $cut, dispatch, dir) {
    let before = $cut.nodeBefore, after = $cut.nodeAfter, conn, match;
    let isolated = before.type.spec.isolating || after.type.spec.isolating;
    if (!isolated && joinMaybeClear(state, $cut, dispatch))
      return true;
    let canDelAfter = !isolated && $cut.parent.canReplace($cut.index(), $cut.index() + 1);
    if (canDelAfter && (conn = (match = before.contentMatchAt(before.childCount)).findWrapping(after.type)) && match.matchType(conn[0] || after.type).validEnd) {
      if (dispatch) {
        let end = $cut.pos + after.nodeSize, wrap2 = Fragment.empty;
        for (let i = conn.length - 1; i >= 0; i--)
          wrap2 = Fragment.from(conn[i].create(null, wrap2));
        wrap2 = Fragment.from(before.copy(wrap2));
        let tr = state.tr.step(new ReplaceAroundStep($cut.pos - 1, end, $cut.pos, end, new Slice(wrap2, 1, 0), conn.length, true));
        let $joinAt = tr.doc.resolve(end + 2 * conn.length);
        if ($joinAt.nodeAfter && $joinAt.nodeAfter.type == before.type && canJoin(tr.doc, $joinAt.pos))
          tr.join($joinAt.pos);
        dispatch(tr.scrollIntoView());
      }
      return true;
    }
    let selAfter = after.type.spec.isolating || dir > 0 && isolated ? null : Selection.findFrom($cut, 1);
    let range = selAfter && selAfter.$from.blockRange(selAfter.$to), target = range && liftTarget(range);
    if (target != null && target >= $cut.depth) {
      if (dispatch)
        dispatch(state.tr.lift(range, target).scrollIntoView());
      return true;
    }
    if (canDelAfter && textblockAt(after, "start", true) && textblockAt(before, "end")) {
      let at = before, wrap2 = [];
      for (; ; ) {
        wrap2.push(at);
        if (at.isTextblock)
          break;
        at = at.lastChild;
      }
      let afterText = after, afterDepth = 1;
      for (; !afterText.isTextblock; afterText = afterText.firstChild)
        afterDepth++;
      if (at.canReplace(at.childCount, at.childCount, afterText.content)) {
        if (dispatch) {
          let end = Fragment.empty;
          for (let i = wrap2.length - 1; i >= 0; i--)
            end = Fragment.from(wrap2[i].copy(end));
          let tr = state.tr.step(new ReplaceAroundStep($cut.pos - wrap2.length, $cut.pos + after.nodeSize, $cut.pos + afterDepth, $cut.pos + after.nodeSize - afterDepth, new Slice(end, wrap2.length, 0), 0, true));
          dispatch(tr.scrollIntoView());
        }
        return true;
      }
    }
    return false;
  }
  function selectTextblockSide(side) {
    return function(state, dispatch) {
      let sel = state.selection, $pos = side < 0 ? sel.$from : sel.$to;
      let depth = $pos.depth;
      while ($pos.node(depth).isInline) {
        if (!depth)
          return false;
        depth--;
      }
      if (!$pos.node(depth).isTextblock)
        return false;
      if (dispatch)
        dispatch(state.tr.setSelection(TextSelection.create(state.doc, side < 0 ? $pos.start(depth) : $pos.end(depth))));
      return true;
    };
  }
  var selectTextblockStart = selectTextblockSide(-1);
  var selectTextblockEnd = selectTextblockSide(1);
  function wrapIn(nodeType, attrs = null) {
    return function(state, dispatch) {
      let { $from, $to } = state.selection;
      let range = $from.blockRange($to), wrapping = range && findWrapping(range, nodeType, attrs);
      if (!wrapping)
        return false;
      if (dispatch)
        dispatch(state.tr.wrap(range, wrapping).scrollIntoView());
      return true;
    };
  }
  function markApplies(doc3, ranges, type, enterAtoms) {
    for (let i = 0; i < ranges.length; i++) {
      let { $from, $to } = ranges[i];
      let can = $from.depth == 0 ? doc3.inlineContent && doc3.type.allowsMarkType(type) : false;
      doc3.nodesBetween($from.pos, $to.pos, (node, pos) => {
        if (can || !enterAtoms && node.isAtom && node.isInline && pos >= $from.pos && pos + node.nodeSize <= $to.pos)
          return false;
        can = node.inlineContent && node.type.allowsMarkType(type);
      });
      if (can)
        return true;
    }
    return false;
  }
  function removeInlineAtoms(ranges) {
    let result = [];
    for (let i = 0; i < ranges.length; i++) {
      let { $from, $to } = ranges[i];
      $from.doc.nodesBetween($from.pos, $to.pos, (node, pos) => {
        if (node.isAtom && node.content.size && node.isInline && pos >= $from.pos && pos + node.nodeSize <= $to.pos) {
          if (pos + 1 > $from.pos)
            result.push(new SelectionRange($from, $from.doc.resolve(pos + 1)));
          $from = $from.doc.resolve(pos + 1 + node.content.size);
          return false;
        }
      });
      if ($from.pos < $to.pos)
        result.push(new SelectionRange($from, $to));
    }
    return result;
  }
  function toggleMark(markType, attrs = null, options) {
    let removeWhenPresent = (options && options.removeWhenPresent) !== false;
    let enterAtoms = (options && options.enterInlineAtoms) !== false;
    let dropSpace = !(options && options.includeWhitespace);
    return function(state, dispatch) {
      let { empty: empty2, $cursor, ranges } = state.selection;
      if (empty2 && !$cursor || !markApplies(state.doc, ranges, markType, enterAtoms))
        return false;
      if (dispatch) {
        if ($cursor) {
          if (markType.isInSet(state.storedMarks || $cursor.marks()))
            dispatch(state.tr.removeStoredMark(markType));
          else
            dispatch(state.tr.addStoredMark(markType.create(attrs)));
        } else {
          let add, tr = state.tr;
          if (!enterAtoms)
            ranges = removeInlineAtoms(ranges);
          if (removeWhenPresent) {
            add = !ranges.some((r) => state.doc.rangeHasMark(r.$from.pos, r.$to.pos, markType));
          } else {
            add = !ranges.every((r) => {
              let missing = false;
              tr.doc.nodesBetween(r.$from.pos, r.$to.pos, (node, pos, parent) => {
                if (missing)
                  return false;
                missing = !markType.isInSet(node.marks) && !!parent && parent.type.allowsMarkType(markType) && !(node.isText && /^\s*$/.test(node.textBetween(Math.max(0, r.$from.pos - pos), Math.min(node.nodeSize, r.$to.pos - pos))));
              });
              return !missing;
            });
          }
          for (let i = 0; i < ranges.length; i++) {
            let { $from, $to } = ranges[i];
            if (!add) {
              tr.removeMark($from.pos, $to.pos, markType);
            } else {
              let from2 = $from.pos, to = $to.pos, start = $from.nodeAfter, end = $to.nodeBefore;
              let spaceStart = dropSpace && start && start.isText ? /^\s*/.exec(start.text)[0].length : 0;
              let spaceEnd = dropSpace && end && end.isText ? /\s*$/.exec(end.text)[0].length : 0;
              if (from2 + spaceStart < to) {
                from2 += spaceStart;
                to -= spaceEnd;
              }
              tr.addMark(from2, to, markType.create(attrs));
            }
          }
          dispatch(tr.scrollIntoView());
        }
      }
      return true;
    };
  }
  function chainCommands(...commands) {
    return function(state, dispatch, view) {
      for (let i = 0; i < commands.length; i++)
        if (commands[i](state, dispatch, view))
          return true;
      return false;
    };
  }
  var backspace = chainCommands(deleteSelection, joinBackward, selectNodeBackward);
  var del = chainCommands(deleteSelection, joinForward, selectNodeForward);
  var pcBaseKeymap = {
    "Enter": chainCommands(newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock),
    "Mod-Enter": exitCode,
    "Backspace": backspace,
    "Mod-Backspace": backspace,
    "Shift-Backspace": backspace,
    "Delete": del,
    "Mod-Delete": del,
    "Mod-a": selectAll
  };
  var macBaseKeymap = {
    "Ctrl-h": pcBaseKeymap["Backspace"],
    "Alt-Backspace": pcBaseKeymap["Mod-Backspace"],
    "Ctrl-d": pcBaseKeymap["Delete"],
    "Ctrl-Alt-Backspace": pcBaseKeymap["Mod-Delete"],
    "Alt-Delete": pcBaseKeymap["Mod-Delete"],
    "Alt-d": pcBaseKeymap["Mod-Delete"],
    "Ctrl-a": selectTextblockStart,
    "Ctrl-e": selectTextblockEnd
  };
  for (let key in pcBaseKeymap)
    macBaseKeymap[key] = pcBaseKeymap[key];
  var mac4 = typeof navigator != "undefined" ? /Mac|iP(hone|[oa]d)/.test(navigator.platform) : typeof os != "undefined" && os.platform ? os.platform() == "darwin" : false;
  var baseKeymap = mac4 ? macBaseKeymap : pcBaseKeymap;

  // node_modules/prosemirror-schema-list/dist/index.js
  function wrapInList(listType, attrs = null) {
    return function(state, dispatch) {
      let { $from, $to } = state.selection;
      let range = $from.blockRange($to);
      if (!range)
        return false;
      let tr = dispatch ? state.tr : null;
      if (!wrapRangeInList(tr, range, listType, attrs))
        return false;
      if (dispatch)
        dispatch(tr.scrollIntoView());
      return true;
    };
  }
  function wrapRangeInList(tr, range, listType, attrs = null) {
    let doJoin = false, outerRange = range, doc3 = range.$from.doc;
    if (range.depth >= 2 && range.$from.node(range.depth - 1).type.compatibleContent(listType) && range.startIndex == 0) {
      if (range.$from.index(range.depth - 1) == 0)
        return false;
      let $insert = doc3.resolve(range.start - 2);
      outerRange = new NodeRange($insert, $insert, range.depth);
      if (range.endIndex < range.parent.childCount)
        range = new NodeRange(range.$from, doc3.resolve(range.$to.end(range.depth)), range.depth);
      doJoin = true;
    }
    let wrap2 = findWrapping(outerRange, listType, attrs, range);
    if (!wrap2)
      return false;
    if (tr)
      doWrapInList(tr, range, wrap2, doJoin, listType);
    return true;
  }
  function doWrapInList(tr, range, wrappers, joinBefore, listType) {
    let content = Fragment.empty;
    for (let i = wrappers.length - 1; i >= 0; i--)
      content = Fragment.from(wrappers[i].type.create(wrappers[i].attrs, content));
    tr.step(new ReplaceAroundStep(range.start - (joinBefore ? 2 : 0), range.end, range.start, range.end, new Slice(content, 0, 0), wrappers.length, true));
    let found2 = 0;
    for (let i = 0; i < wrappers.length; i++)
      if (wrappers[i].type == listType)
        found2 = i + 1;
    let splitDepth = wrappers.length - found2;
    let splitPos = range.start + wrappers.length - (joinBefore ? 2 : 0), parent = range.parent;
    for (let i = range.startIndex, e = range.endIndex, first = true; i < e; i++, first = false) {
      if (!first && splitDepth && canSplit(tr.doc, splitPos, splitDepth)) {
        tr.split(splitPos, splitDepth);
        splitPos += 2 * splitDepth;
      }
      splitPos += parent.child(i).nodeSize;
    }
    return tr;
  }
  function isItem(itemType, type) {
    return itemType instanceof NodeType ? type == itemType : itemType.indexOf(type) > -1;
  }
  function splitListItem(itemType, itemAttrs) {
    return function(state, dispatch) {
      let { $from, $to, node } = state.selection;
      if (node && node.isBlock || $from.depth < 2 || !$from.sameParent($to))
        return false;
      let grandParent = $from.node(-1);
      if (!isItem(itemType, grandParent.type))
        return false;
      if ($from.parent.content.size == 0 && $from.node(-1).childCount == $from.indexAfter(-1)) {
        if ($from.depth == 3 || !isItem(itemType, $from.node(-3).type) || $from.index(-2) != $from.node(-2).childCount - 1)
          return false;
        if (dispatch) {
          let wrap2 = Fragment.empty;
          let depthBefore = $from.index(-1) ? 1 : $from.index(-2) ? 2 : 3;
          for (let d = $from.depth - depthBefore; d >= $from.depth - 3; d--)
            wrap2 = Fragment.from($from.node(d).copy(wrap2));
          let depthAfter = $from.indexAfter(-1) < $from.node(-2).childCount ? 1 : $from.indexAfter(-2) < $from.node(-3).childCount ? 2 : 3;
          wrap2 = wrap2.append(Fragment.from($from.node(-3).type.createAndFill()));
          let start = $from.before($from.depth - (depthBefore - 1));
          let tr2 = state.tr.replace(start, $from.after(-depthAfter), new Slice(wrap2, 4 - depthBefore, 0));
          let sel = -1;
          tr2.doc.nodesBetween(start, tr2.doc.content.size, (node2, pos) => {
            if (sel > -1)
              return false;
            if (node2.isTextblock && node2.content.size == 0)
              sel = pos + 1;
          });
          if (sel > -1)
            tr2.setSelection(Selection.near(tr2.doc.resolve(sel)));
          dispatch(tr2.scrollIntoView());
        }
        return true;
      }
      let nextType = $to.pos == $from.end() ? grandParent.contentMatchAt(0).defaultType : null;
      let tr = state.tr.delete($from.pos, $to.pos);
      let types = nextType || itemAttrs ? [
        itemAttrs ? { type: grandParent.type, attrs: itemAttrs } : null,
        nextType ? { type: nextType } : null
      ] : void 0;
      if (!canSplit(tr.doc, $from.pos, 2, types))
        return false;
      if (dispatch)
        dispatch(tr.split($from.pos, 2, types).scrollIntoView());
      return true;
    };
  }
  function liftListItem(itemType) {
    return function(state, dispatch) {
      let { $from, $to } = state.selection;
      let range = $from.blockRange($to, (node) => node.childCount > 0 && isItem(itemType, node.firstChild.type));
      if (!range)
        return false;
      if (!dispatch)
        return true;
      if (isItem(itemType, $from.node(range.depth - 1).type))
        return liftToOuterList(state, dispatch, range);
      else
        return liftOutOfList(state, dispatch, range);
    };
  }
  function liftToOuterList(state, dispatch, range) {
    let tr = state.tr, end = range.end, endOfList = range.$to.end(range.depth);
    let itemType = range.parent.child(range.endIndex - 1).type;
    if (end < endOfList) {
      tr.step(new ReplaceAroundStep(end - 1, endOfList, end, endOfList, new Slice(Fragment.from(itemType.create(null, range.parent.copy())), 1, 0), 1, true));
      range = new NodeRange(tr.doc.resolve(range.$from.pos), tr.doc.resolve(endOfList), range.depth);
    }
    const target = liftTarget(range);
    if (target == null)
      return false;
    tr.lift(range, target);
    let $after = tr.doc.resolve(tr.mapping.map(end, -1) - 1);
    if (canJoin(tr.doc, $after.pos) && $after.nodeBefore.type == $after.nodeAfter.type)
      tr.join($after.pos);
    dispatch(tr.scrollIntoView());
    return true;
  }
  function liftOutOfList(state, dispatch, range) {
    let tr = state.tr, list = range.parent;
    for (let pos = range.end, i = range.endIndex - 1, e = range.startIndex; i > e; i--) {
      pos -= list.child(i).nodeSize;
      tr.delete(pos - 1, pos + 1);
    }
    let $start = tr.doc.resolve(range.start), item = $start.nodeAfter;
    if (tr.mapping.map(range.end) != range.start + $start.nodeAfter.nodeSize)
      return false;
    let atStart = range.startIndex == 0, atEnd = range.endIndex == list.childCount;
    let parent = $start.node(-1), indexBefore = $start.index(-1);
    if (!parent.canReplace(indexBefore + (atStart ? 0 : 1), indexBefore + 1, item.content.append(atEnd ? Fragment.empty : Fragment.from(list))))
      return false;
    let start = $start.pos, end = start + item.nodeSize;
    tr.step(new ReplaceAroundStep(start - (atStart ? 1 : 0), end + (atEnd ? 1 : 0), start + 1, end - 1, new Slice((atStart ? Fragment.empty : Fragment.from(list.copy(Fragment.empty))).append(atEnd ? Fragment.empty : Fragment.from(list.copy(Fragment.empty))), atStart ? 0 : 1, atEnd ? 0 : 1), atStart ? 0 : 1));
    dispatch(tr.scrollIntoView());
    return true;
  }
  function sinkListItem(itemType) {
    return function(state, dispatch) {
      let { $from, $to } = state.selection;
      let range = $from.blockRange($to, (node) => node.childCount > 0 && isItem(itemType, node.firstChild.type));
      if (!range)
        return false;
      let startIndex = range.startIndex;
      if (startIndex == 0)
        return false;
      let parent = range.parent, nodeBefore = parent.child(startIndex - 1);
      if (!isItem(itemType, nodeBefore.type))
        return false;
      if (dispatch) {
        let nestedBefore = nodeBefore.lastChild && nodeBefore.lastChild.type == parent.type;
        let inner = Fragment.from(nestedBefore ? nodeBefore.lastChild.lastChild.type.create() : null);
        let slice2 = new Slice(Fragment.from(nodeBefore.type.create(null, Fragment.from(parent.type.create(null, inner)))), nestedBefore ? 3 : 1, 0);
        let before = range.start, after = range.end;
        dispatch(state.tr.step(new ReplaceAroundStep(before - (nestedBefore ? 3 : 1), after, before, after, slice2, 1, true)).scrollIntoView());
      }
      return true;
    };
  }

  // node_modules/prosemirror-inputrules/dist/index.js
  var InputRule = class {
    /**
    Create an input rule. The rule applies when the user typed
    something and the text directly in front of the cursor matches
    `match`, which should end with `$`.
    
    The `handler` can be a string, in which case the matched text, or
    the first matched group in the regexp, is replaced by that
    string.
    
    Or a it can be a function, which will be called with the match
    array produced by
    [`RegExp.exec`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/RegExp/exec),
    as well as the start and end of the matched range and the text
    that was typed to trigger the rule (which won't be in the
    document yet), and which can return a
    [transaction](https://prosemirror.net/docs/ref/#state.Transaction) that describes the rule's
    effect or null to indicate the input was not handled.
    */
    constructor(match, handler, options = {}) {
      this.match = match;
      this.match = match;
      this.handler = typeof handler == "string" ? stringHandler(handler) : handler;
      this.undoable = options.undoable !== false;
      this.inCode = options.inCode || false;
      this.inCodeMark = options.inCodeMark !== false;
    }
  };
  function stringHandler(string) {
    return function(state, match, start, end) {
      let insert = string;
      if (match[1]) {
        let offset = match[0].lastIndexOf(match[1]);
        insert += match[0].slice(offset + match[1].length);
        start += offset;
        let cutOff = start - end;
        if (cutOff > 0) {
          insert = match[0].slice(offset - cutOff, offset) + insert;
          start = end;
        }
      }
      return state.tr.insertText(insert, start, end);
    };
  }
  var MAX_MATCH = 500;
  function inputRules({ rules }) {
    let plugin = new Plugin({
      state: {
        init() {
          return null;
        },
        apply(tr, prev) {
          let stored = tr.getMeta(this);
          if (stored)
            return stored;
          return tr.selectionSet || tr.docChanged ? null : prev;
        }
      },
      props: {
        handleTextInput(view, from2, to, text) {
          return run(view, from2, to, text, rules, plugin);
        },
        handleDOMEvents: {
          compositionend: (view) => {
            setTimeout(() => {
              let { $cursor } = view.state.selection;
              if ($cursor)
                run(view, $cursor.pos, $cursor.pos, "", rules, plugin);
            });
          }
        }
      },
      isInputRules: true
    });
    return plugin;
  }
  function run(view, from2, to, text, rules, plugin) {
    if (view.composing)
      return false;
    let state = view.state, $from = state.doc.resolve(from2), sel = view.state.selection;
    let textBefore = $from.parent.textBetween(Math.max(0, $from.parentOffset - MAX_MATCH), $from.parentOffset, null, "\uFFFC") + text;
    let marks2 = from2 == sel.from && to == sel.to && view.state.storedMarks || (from2 == to ? $from.marks() : $from.marksAcross(state.doc.resolve(to)) || []);
    for (let i = 0; i < rules.length; i++) {
      let rule = rules[i];
      if (!rule.inCodeMark && marks2.some((m) => m.type.spec.code))
        continue;
      if ($from.parent.type.spec.code) {
        if (!rule.inCode)
          continue;
      } else if (rule.inCode === "only") {
        continue;
      }
      let match = rule.match.exec(textBefore);
      if (!match || match[0].length < text.length)
        continue;
      let startPos = from2 - (match[0].length - text.length);
      if (!rule.inCodeMark) {
        let hasMark = false;
        state.doc.nodesBetween(startPos, $from.pos, (node) => {
          if (node.isInline && node.marks.some((m) => m.type.spec.code))
            hasMark = true;
        });
        if (hasMark)
          continue;
      }
      let tr = rule.handler(state, match, startPos, to, text);
      if (!tr)
        continue;
      if (rule.undoable)
        tr.setMeta(plugin, { transform: tr, from: from2, to, text });
      view.dispatch(tr);
      return true;
    }
    return false;
  }
  var emDash = new InputRule(/--$/, "\u2014", { inCodeMark: false });
  var ellipsis = new InputRule(/\.\.\.$/, "\u2026", { inCodeMark: false });
  var openDoubleQuote = new InputRule(/(?:^|[\s\{\[\(\<'"\u2018\u201C])(")$/, "\u201C", { inCodeMark: false });
  var closeDoubleQuote = new InputRule(/"$/, "\u201D", { inCodeMark: false });
  var openSingleQuote = new InputRule(/(?:^|[\s\{\[\(\<'"\u2018\u201C])(')$/, "\u2018", { inCodeMark: false });
  var closeSingleQuote = new InputRule(/'$/, "\u2019", { inCodeMark: false });

  // src/commands.js
  function isMarkActive(state, markType) {
    const { from: from2, $from, to, empty: empty2 } = state.selection;
    if (empty2) {
      return !!markType.isInSet(state.storedMarks || $from.marks());
    }
    return state.doc.rangeHasMark(from2, to, markType);
  }
  function insideCellOrProtected(state, schema2) {
    const { $from, $to, from: from2, to } = state.selection;
    for (let d = $from.depth; d > 0; d--) {
      const n = $from.node(d);
      if (n.type === schema2.nodes.math_block || n.type === schema2.nodes.opaque_block) {
        return { protectedAtom: true, containsProtected: true, inTable: false, cell: null };
      }
    }
    if (state.selection instanceof NodeSelection) {
      const t = state.selection.node.type;
      if (t === schema2.nodes.math_inline || t === schema2.nodes.opaque_inline || t === schema2.nodes.math_block || t === schema2.nodes.opaque_block) {
        return { protectedAtom: true, containsProtected: true, inTable: false, cell: null };
      }
    }
    let containsProtected = false;
    let containsTable = false;
    if (from2 < to) {
      state.doc.nodesBetween(from2, to, (node) => {
        if (node.type === schema2.nodes.table || node.type === schema2.nodes.table_cell || node.type === schema2.nodes.table_header) {
          containsTable = true;
        }
        if (node.type === schema2.nodes.math_inline || node.type === schema2.nodes.opaque_inline || node.type === schema2.nodes.math_block || node.type === schema2.nodes.opaque_block) {
          containsProtected = true;
          return false;
        }
        return true;
      });
    }
    for (const $pos of [$from, $to]) {
      for (let d = $pos.depth; d > 0; d--) {
        const n = $pos.node(d);
        if (n.type === schema2.nodes.table_cell || n.type === schema2.nodes.table_header) {
          return { protectedAtom: false, containsProtected, inTable: true, cell: { node: n, pos: $pos.before(d) } };
        }
      }
    }
    return { protectedAtom: false, containsProtected, inTable: containsTable, cell: null };
  }
  function unwrapBlockquote(state, dispatch, schema2) {
    const { $from, $to } = state.selection;
    const range = $from.blockRange($to, (node) => node.type === schema2.nodes.blockquote);
    if (!range) return false;
    const target = liftTarget(range);
    if (target == null) return false;
    if (dispatch) dispatch(state.tr.lift(range, target).scrollIntoView());
    return true;
  }
  function findAncestorOfType(pos, type) {
    for (let d = pos.depth; d >= 0; d--) {
      if (pos.node(d).type === type) return { depth: d, node: pos.node(d), pos: pos.before(d) };
    }
    return null;
  }
  function findNearestListAncestor(pos, schema2) {
    for (let d = pos.depth; d > 0; d--) {
      const n = pos.node(d);
      if (n.type === schema2.nodes.bullet_list || n.type === schema2.nodes.ordered_list) {
        return { depth: d, node: n, pos: pos.before(d) };
      }
    }
    return null;
  }
  function inlineMarkTypesToStrip(schema2) {
    const names = ["strong", "em", "code", "highlight", "strike", "link", ...INLINE_HTML_MARK_NAMES];
    return names.map((name) => schema2.marks[name]).filter(Boolean);
  }
  function splitLeafByHardBreaksIfPartial(tr, schema2, node, pos, selFrom, selTo, level) {
    if (node.type !== schema2.nodes.paragraph && node.type !== schema2.nodes.blank_line) return null;
    const lines = [];
    let currentNodes = [];
    let lineStartOffset = 0;
    let cursorOffset = 0;
    node.content.forEach((child) => {
      if (child.type === schema2.nodes.hard_break) {
        lines.push({ nodes: currentNodes, start: lineStartOffset, end: cursorOffset });
        currentNodes = [];
        cursorOffset += child.nodeSize;
        lineStartOffset = cursorOffset;
      } else {
        currentNodes.push(child);
        cursorOffset += child.nodeSize;
      }
    });
    lines.push({ nodes: currentNodes, start: lineStartOffset, end: cursorOffset });
    if (lines.length <= 1) return null;
    const contentStart = pos + 1;
    const lineMatches = (line) => {
      const absStart = contentStart + line.start;
      const absEnd = contentStart + line.end;
      if (selFrom === selTo) return selFrom >= absStart && selFrom <= absEnd;
      return Math.max(absStart, selFrom) <= Math.min(absEnd, selTo) && !(selFrom === absEnd && selTo > absEnd) && !(selTo === absStart && selFrom < absStart);
    };
    const touched = lines.map(lineMatches);
    if (touched.every(Boolean) || !touched.some(Boolean)) return null;
    const replacementBlocks = [];
    let usedOrigin = false;
    let pendingParagraphNodes = [];
    let headingRange = null;
    let runningPos = pos;
    const originAttrs = () => {
      if (usedOrigin) return { mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 };
      usedOrigin = true;
      return {
        mdContext: node.attrs.mdContext || "",
        mdBlockId: node.attrs.mdBlockId || null,
        mdBlockSub: node.attrs.mdBlockSub || 0,
        mdBlockTotal: node.attrs.mdBlockTotal || 1
      };
    };
    const flushParagraph = () => {
      if (!pendingParagraphNodes.length) return;
      const p = schema2.nodes.paragraph.create({ ...originAttrs(), mdEmpty: false }, Fragment.fromArray(pendingParagraphNodes));
      replacementBlocks.push(p);
      runningPos += p.nodeSize;
      pendingParagraphNodes = [];
    };
    lines.forEach((line, index) => {
      const content = Fragment.fromArray(line.nodes);
      if (touched[index]) {
        flushParagraph();
        const h = schema2.nodes.heading.create({
          level,
          outlineIgnore: false,
          ...originAttrs()
        }, content);
        if (!headingRange) headingRange = { from: runningPos + 1, to: runningPos + 1 + h.content.size };
        else headingRange.to = runningPos + 1 + h.content.size;
        replacementBlocks.push(h);
        runningPos += h.nodeSize;
      } else if (content.size === 0) {
        flushParagraph();
        const b = schema2.nodes.blank_line.create();
        replacementBlocks.push(b);
        runningPos += b.nodeSize;
      } else {
        if (pendingParagraphNodes.length) {
          pendingParagraphNodes.push(schema2.nodes.hard_break.create());
        }
        line.nodes.forEach((n) => pendingParagraphNodes.push(n));
      }
    });
    flushParagraph();
    if (!replacementBlocks.length) return null;
    tr.replaceWith(pos, pos + node.nodeSize, replacementBlocks);
    return headingRange || { from: pos + 1, to: pos + 1 };
  }
  function liftSelectedListItemsWithOrder(state, schema2) {
    const { $from, $to, empty: empty2, from: from2, to } = state.selection;
    const listAncestor = findNearestListAncestor($from, schema2);
    if (!listAncestor || $to.depth < listAncestor.depth || $to.before(listAncestor.depth) !== listAncestor.pos) return null;
    const { node: listNode, pos: listPos } = listAncestor;
    const isOrdered = listNode.type === schema2.nodes.ordered_list;
    const baseOrder = isOrdered ? Math.max(0, Number(listNode.attrs.order ?? 1)) : 1;
    const firstIdx = $from.index(listAncestor.depth);
    const lastIdx = $to.index(listAncestor.depth);
    const nested = $from.node(listAncestor.depth - 1).type === schema2.nodes.list_item;
    if (nested || firstIdx === lastIdx && lastIdx === listNode.childCount - 1) {
      let liftTr = null;
      if (liftListItem(schema2.nodes.list_item)(state, (t) => {
        liftTr = t;
      })) {
        if (nested && isOrdered) {
          const lifted = $from.blockRange($to, (node) => node.firstChild?.type === schema2.nodes.list_item);
          if (lifted && lifted.depth === listAncestor.depth && lifted.endIndex < listNode.childCount) {
            const remainingPos = liftTr.mapping.map(lifted.end + 1);
            const remaining = findNearestListAncestor(liftTr.doc.resolve(remainingPos), schema2);
            if (remaining?.node.type === listNode.type && remaining.node.firstChild === listNode.child(lifted.endIndex)) {
              liftTr.setNodeMarkup(remaining.pos, null, { ...remaining.node.attrs, order: baseOrder + lifted.endIndex });
            }
          }
        }
        return liftTr;
      }
      return null;
    }
    const beforeItems = [];
    const liftedBlocks = [];
    const afterItems = [];
    const itemRelFrom = (() => {
      let itemStart = listPos + 1;
      for (let i = 0; i < firstIdx; i++) itemStart += listNode.child(i).nodeSize;
      return Math.max(0, from2 - (itemStart + 1));
    })();
    const itemRelEndFromEnd = (() => {
      let itemStart = listPos + 1;
      for (let i = 0; i <= lastIdx; i++) {
        const sz = listNode.child(i).nodeSize;
        if (i === lastIdx) {
          const contentEnd = itemStart + sz - 1;
          return Math.max(0, contentEnd - to);
        }
        itemStart += sz;
      }
      return 0;
    })();
    for (let i = 0; i < listNode.childCount; i++) {
      const item = listNode.child(i);
      if (i < firstIdx) {
        beforeItems.push(item);
      } else if (i <= lastIdx) {
        item.content.forEach((block) => {
          if (block.attrs && "mdBlockId" in block.attrs) {
            liftedBlocks.push(block.type.create({ ...block.attrs, mdContext: "", mdBlockId: null }, block.content, block.marks));
          } else {
            liftedBlocks.push(block);
          }
        });
      } else {
        afterItems.push(item);
      }
    }
    const replacements = [];
    if (beforeItems.length) {
      replacements.push(listNode.type.create({ ...listNode.attrs }, beforeItems));
    }
    replacements.push(...liftedBlocks);
    if (afterItems.length) {
      const afterAttrs = isOrdered ? { ...listNode.attrs, mdContext: "", mdBlockId: null, order: baseOrder + lastIdx + 1 } : { ...listNode.attrs, mdContext: "", mdBlockId: null };
      replacements.push(listNode.type.create(afterAttrs, afterItems));
    }
    const tr = state.tr.replaceWith(listPos, listPos + listNode.nodeSize, replacements);
    let liftedStart = listPos;
    if (beforeItems.length) liftedStart += replacements[0].nodeSize;
    const liftedSize = liftedBlocks.reduce((sum, b) => sum + b.nodeSize, 0);
    const liftedEnd = liftedStart + liftedSize;
    if (empty2) {
      const targetPos = Math.min(liftedEnd, liftedStart + itemRelFrom);
      tr.setSelection(TextSelection.near(tr.doc.resolve(targetPos)));
    } else {
      const selStart = Math.min(liftedEnd, liftedStart + itemRelFrom);
      const selEnd = Math.max(selStart, liftedEnd - itemRelEndFromEnd);
      tr.setSelection(TextSelection.between(
        tr.doc.resolve(selStart),
        tr.doc.resolve(selEnd)
      ));
    }
    return tr;
  }
  function convertCodeLineBreaks(tr, node, pos, schema2) {
    if (node.type !== schema2.nodes.code_block) return;
    const lines = node.textContent.split("\n");
    if (lines.length === 1) return;
    const content = [];
    lines.forEach((line, index) => {
      if (index) content.push(schema2.nodes.hard_break.create());
      if (line) content.push(schema2.text(line));
    });
    const selection = tr.selection.toJSON();
    tr.replaceWith(pos + 1, pos + node.nodeSize - 1, content);
    tr.setSelection(Selection.fromJSON(tr.doc, selection));
  }
  function applyHeadingOrParagraph(state, dispatch, schema2, { level = null, preserveInlineMarks = false }) {
    const ctx = insideCellOrProtected(state, schema2);
    if (level === null && ctx.inTable && ctx.cell) {
      const from3 = ctx.cell.pos + 1;
      const to2 = ctx.cell.pos + ctx.cell.node.nodeSize - 1;
      const marksToRemove = inlineMarkTypesToStrip(schema2);
      let anyMark = false;
      state.doc.nodesBetween(from3, to2, (node) => {
        if (node.marks?.some((m) => marksToRemove.includes(m.type))) anyMark = true;
      });
      if (!anyMark) return { handled: true, changed: false, reason: "idempotent" };
      if (dispatch) {
        const tr = state.tr;
        for (const m of marksToRemove) tr.removeMark(from3, to2, m);
        dispatch(tr.scrollIntoView());
      }
      return { handled: true, changed: anyMark };
    }
    function findAnyListItemInSelection(selState) {
      const { from: sFrom, to: sTo, $from: s$From, $to: s$To } = selState.selection;
      const ancFrom = findAncestorOfType(s$From, schema2.nodes.list_item);
      if (ancFrom) {
        const listAnc = findNearestListAncestor(s$From, schema2);
        if (listAnc) {
          const listEnd = listAnc.pos + listAnc.node.nodeSize - 1;
          return {
            listPos: listAnc.pos,
            listEnd: listAnc.pos + listAnc.node.nodeSize,
            itemFrom: sFrom,
            itemTo: Math.min(sTo, listEnd),
            containsStart: true,
            containsEnd: sTo <= listEnd + 1
          };
        }
      }
      let found2 = null;
      selState.doc.nodesBetween(sFrom, sTo, (node, pos) => {
        if (found2) return false;
        if (node.type === schema2.nodes.bullet_list || node.type === schema2.nodes.ordered_list) {
          found2 = {
            listPos: pos,
            listEnd: pos + node.nodeSize,
            itemFrom: Math.max(sFrom, pos + 2),
            itemTo: Math.min(sTo, pos + node.nodeSize - 2),
            containsStart: sFrom >= pos,
            containsEnd: sTo <= pos + node.nodeSize
          };
          return false;
        }
        return true;
      });
      return found2;
    }
    const steps = [];
    let workState = state;
    let liftSafety = 0;
    while (liftSafety < 32) {
      const targetList = findAnyListItemInSelection(workState);
      if (!targetList) break;
      liftSafety++;
      const origSel = workState.selection;
      const subSelState = workState.apply(
        workState.tr.setSelection(TextSelection.between(
          workState.doc.resolve(targetList.itemFrom),
          workState.doc.resolve(Math.max(targetList.itemFrom, targetList.itemTo))
        ))
      );
      const liftTr = liftSelectedListItemsWithOrder(subSelState, schema2);
      if (!liftTr) break;
      const nextFrom = targetList.containsStart ? liftTr.selection.from : Math.max(0, liftTr.mapping.map(origSel.from, -1));
      const nextTo = targetList.containsEnd ? liftTr.selection.to : Math.min(liftTr.doc.content.size, liftTr.mapping.map(origSel.to, 1));
      liftTr.setSelection(
        origSel.empty ? TextSelection.near(liftTr.doc.resolve(nextFrom)) : TextSelection.between(liftTr.doc.resolve(nextFrom), liftTr.doc.resolve(Math.max(nextFrom, nextTo)))
      );
      steps.push(liftTr);
      workState = workState.apply(liftTr);
    }
    if (level === null) {
      let safety = 0;
      while ((findAncestorOfType(workState.selection.$from, schema2.nodes.blockquote) || findAncestorOfType(workState.selection.$to, schema2.nodes.blockquote)) && safety < 16) {
        safety++;
        let bqTr = null;
        if (!lift2(workState, (t) => {
          bqTr = t;
        })) break;
        steps.push(bqTr);
        workState = workState.apply(bqTr);
      }
    }
    const { $from, $to, from: from2, to } = workState.selection;
    const range = $from.blockRange($to);
    if (!range) {
      if (!steps.length) return { handled: false, changed: false };
      if (dispatch) dispatchMerged(state, steps, dispatch);
      return { handled: true, changed: true };
    }
    const targets = [];
    workState.doc.nodesBetween(range.start, range.end, (node, pos) => {
      if (node.type === schema2.nodes.paragraph || node.type === schema2.nodes.blank_line || node.type === schema2.nodes.heading || node.type === schema2.nodes.code_block) {
        targets.push({ node, pos });
        return false;
      }
      if (node.type === schema2.nodes.table || node.type === schema2.nodes.math_block || node.type === schema2.nodes.opaque_block) {
        return false;
      }
      return true;
    });
    if (!targets.length) {
      if (!steps.length) return { handled: false, changed: false };
      if (dispatch) dispatchMerged(state, steps, dispatch);
      return { handled: true, changed: true };
    }
    const editTr = workState.tr;
    let blockChanged = false;
    let splitSelection = null;
    if (level != null) {
      for (let i = targets.length - 1; i >= 0; i--) {
        const { node, pos } = targets[i];
        const splitRange = splitLeafByHardBreaksIfPartial(editTr, schema2, node, pos, from2, to, level);
        if (splitRange) {
          splitSelection = splitRange;
          blockChanged = true;
          continue;
        }
        if (node.type === schema2.nodes.heading && node.attrs.level === level) {
          continue;
        }
        editTr.setNodeMarkup(pos, schema2.nodes.heading, {
          level,
          outlineIgnore: false,
          mdContext: node.attrs.mdContext || "",
          mdBlockId: node.attrs.mdBlockId || null,
          mdBlockSub: node.attrs.mdBlockSub || 0,
          mdBlockTotal: node.attrs.mdBlockTotal || 1
        }, node.marks);
        convertCodeLineBreaks(editTr, node, pos, schema2);
        blockChanged = true;
      }
      if (splitSelection) {
        editTr.setSelection(
          from2 === to ? TextSelection.near(editTr.doc.resolve(splitSelection.from)) : TextSelection.between(editTr.doc.resolve(splitSelection.from), editTr.doc.resolve(splitSelection.to))
        );
      }
    } else {
      const marksToRemove = preserveInlineMarks ? [] : inlineMarkTypesToStrip(schema2);
      for (let i = targets.length - 1; i >= 0; i--) {
        const { node, pos } = targets[i];
        if (node.type !== schema2.nodes.paragraph) {
          editTr.setNodeMarkup(pos, schema2.nodes.paragraph, {
            mdEmpty: false,
            mdContext: node.attrs.mdContext || "",
            mdBlockId: node.attrs.mdBlockId || null,
            mdBlockSub: node.attrs.mdBlockSub || 0,
            mdBlockTotal: node.attrs.mdBlockTotal || 1
          }, node.marks);
          convertCodeLineBreaks(editTr, node, pos, schema2);
          blockChanged = true;
        }
        if (!marksToRemove.length) continue;
        const cFrom = pos + 1;
        const cTo = pos + node.nodeSize - 1;
        let hasMark = false;
        workState.doc.nodesBetween(cFrom, cTo, (child) => {
          if (child.marks?.some((m) => marksToRemove.includes(m.type))) hasMark = true;
        });
        if (hasMark) {
          for (const m of marksToRemove) editTr.removeMark(cFrom, cTo, m);
          blockChanged = true;
        }
      }
    }
    if (blockChanged) steps.push(editTr);
    if (!steps.length) {
      return { handled: true, changed: false, reason: "idempotent" };
    }
    if (dispatch) dispatchMerged(state, steps, dispatch);
    return { handled: true, changed: true };
  }
  function dispatchMerged(baseState, transactions, dispatch) {
    const combined = baseState.tr;
    for (const t of transactions) {
      for (const s of t.steps) combined.step(s);
    }
    const last = transactions.at(-1);
    if (last?.selection && transactions.some((t) => t.selectionSet)) {
      combined.setSelection(Selection.fromJSON(combined.doc, last.selection.toJSON()));
    }
    dispatch(combined.scrollIntoView());
  }
  function toggleListMode(state, dispatch, schema2, mode) {
    const { $from, $to, from: from2, to } = state.selection;
    const fromList = findNearestListAncestor($from, schema2);
    const spansOutsideSingleList = from2 < to && (!fromList || $to.depth < fromList.depth || $to.before(fromList.depth) !== fromList.pos);
    let touchesListInMixedRange = false;
    if (spansOutsideSingleList) {
      state.doc.nodesBetween(from2, to, (node) => {
        if (node.type === schema2.nodes.bullet_list || node.type === schema2.nodes.ordered_list) {
          touchesListInMixedRange = true;
          return false;
        }
        return true;
      });
    }
    if (spansOutsideSingleList && mode === "task" && !touchesListInMixedRange) {
    } else if (spansOutsideSingleList && touchesListInMixedRange) {
      if (mode === "task") {
        const itemTargets = [];
        const listContainersToConvert = [];
        state.doc.nodesBetween(from2, to, (node, pos) => {
          if (node.type === schema2.nodes.ordered_list) listContainersToConvert.push({ node, pos });
          if (node.type === schema2.nodes.list_item) itemTargets.push({ node, pos });
          return true;
        });
        if (itemTargets.length > 0) {
          const allAlreadyTask = itemTargets.every((it) => it.node.attrs.task !== null) && !listContainersToConvert.length;
          if (!allAlreadyTask) {
            if (!dispatch) return true;
            const tr = state.tr;
            for (const { node, pos } of listContainersToConvert) {
              tr.setNodeMarkup(pos, schema2.nodes.bullet_list, {
                mdContext: node.attrs.mdContext || "",
                mdBlockId: node.attrs.mdBlockId || null,
                mdBlockSub: node.attrs.mdBlockSub || 0,
                mdBlockTotal: node.attrs.mdBlockTotal || 1,
                tight: node.attrs.tight !== false
              });
            }
            for (const { node, pos } of itemTargets) {
              if (node.attrs.task === null) tr.setNodeMarkup(pos, null, { ...node.attrs, task: false });
            }
            dispatch(tr.scrollIntoView());
            return true;
          }
          const liftAll = applyHeadingOrParagraph(state, dispatch, schema2, { level: null });
          return liftAll.handled;
        }
      }
      if (!dispatch) return true;
      const order = mode === "ordered" && fromList?.node.type === schema2.nodes.ordered_list ? fromList.node.attrs.order + $from.index(fromList.depth) : 1;
      let workState = state;
      const mixedSteps = [];
      applyHeadingOrParagraph(state, (tr) => {
        mixedSteps.push(tr);
        workState = state.apply(tr);
      }, schema2, { preserveInlineMarks: true });
      const listType2 = mode === "ordered" ? schema2.nodes.ordered_list : schema2.nodes.bullet_list;
      const { $from: wFrom, $to: wTo } = workState.selection;
      const wRange = wFrom.blockRange(wTo);
      if (!wRange) return false;
      const prepTr2 = workState.tr;
      let convertedBlank2 = false;
      workState.doc.nodesBetween(wRange.start, wRange.end, (node, pos) => {
        if (node.type === schema2.nodes.blank_line) {
          prepTr2.setNodeMarkup(pos, schema2.nodes.paragraph, {
            mdContext: node.attrs.mdContext || "",
            mdBlockId: node.attrs.mdBlockId || null,
            mdBlockSub: node.attrs.mdBlockSub || 0,
            mdBlockTotal: node.attrs.mdBlockTotal || 1,
            mdEmpty: false
          });
          convertedBlank2 = true;
          return false;
        }
        return true;
      });
      if (convertedBlank2) {
        mixedSteps.push(prepTr2);
        workState = workState.apply(prepTr2);
      }
      let wrapped = false;
      const listAttrs = mode === "ordered" ? { tight: true, order } : { tight: true };
      wrapInList(listType2, listAttrs)(workState, (tr2) => {
        if (mode === "task") {
          const markFrom = Math.min(tr2.selection.from, tr2.doc.content.size);
          const markTo = Math.min(tr2.selection.to, tr2.doc.content.size);
          tr2.doc.nodesBetween(markFrom, markTo, (node, pos) => {
            if (node.type === schema2.nodes.list_item && node.attrs.task === null) {
              tr2.setNodeMarkup(pos, null, { ...node.attrs, task: false });
            }
            return true;
          });
        }
        mixedSteps.push(tr2);
        dispatchMerged(state, mixedSteps, dispatch);
        wrapped = true;
      });
      return wrapped;
    }
    if (fromList) {
      const parentList = fromList.node;
      const isOrdered = parentList.type === schema2.nodes.ordered_list;
      const range2 = $from.blockRange($to);
      const touchedItems = [];
      const untouchedBefore = [];
      const untouchedAfter = [];
      let offset = fromList.pos + 1;
      let firstTouchedIdx = -1;
      let lastTouchedIdx = -1;
      for (let i = 0; i < parentList.childCount; i++) {
        const child = parentList.child(i);
        const childEnd = offset + child.nodeSize;
        const hits = !range2 || childEnd > range2.start && offset < range2.end;
        if (hits) {
          if (firstTouchedIdx < 0) firstTouchedIdx = i;
          lastTouchedIdx = i;
          touchedItems.push({ child, pos: offset, index: i });
        } else if (firstTouchedIdx < 0) {
          untouchedBefore.push(child);
        } else {
          untouchedAfter.push(child);
        }
        offset = childEnd;
      }
      const matchesSame = touchedItems.length > 0 && (mode === "ordered" && isOrdered || mode === "bullet" && !isOrdered && touchedItems.every((it) => it.child.attrs.task === null) || mode === "task" && !isOrdered && touchedItems.every((it) => it.child.attrs.task !== null));
      if (matchesSame) {
        if (!dispatch) return true;
        const tr2 = liftSelectedListItemsWithOrder(state, schema2);
        if (!tr2) return false;
        dispatch(tr2.scrollIntoView());
        return true;
      }
      if (!dispatch) return true;
      const targetListType = mode === "ordered" ? schema2.nodes.ordered_list : schema2.nodes.bullet_list;
      const partialSplit = (untouchedBefore.length > 0 || untouchedAfter.length > 0) && parentList.type !== targetListType;
      if (partialSplit) {
        const convertedItems = touchedItems.map(
          ({ child }) => child.type.create({ ...child.attrs, task: mode === "task" ? child.attrs.task ?? false : null }, child.content, child.marks)
        );
        const replacements = [];
        if (untouchedBefore.length) {
          replacements.push(parentList.type.create({ ...parentList.attrs }, untouchedBefore));
        }
        const midAttrs = mode === "ordered" ? { mdContext: "", mdBlockId: null, order: 1, tight: parentList.attrs.tight !== false } : { mdContext: "", mdBlockId: null, tight: parentList.attrs.tight !== false };
        replacements.push(targetListType.create(midAttrs, convertedItems));
        if (untouchedAfter.length) {
          const afterAttrs = isOrdered ? { ...parentList.attrs, mdContext: "", mdBlockId: null, order: (parentList.attrs.order ?? 1) + lastTouchedIdx + 1 } : { ...parentList.attrs, mdContext: "", mdBlockId: null };
          replacements.push(parentList.type.create(afterAttrs, untouchedAfter));
        }
        const tr2 = state.tr.replaceWith(fromList.pos, fromList.pos + parentList.nodeSize, replacements);
        dispatch(tr2.scrollIntoView());
        return true;
      }
      const tr = state.tr;
      const listAttrs = mode === "ordered" ? {
        mdContext: parentList.attrs.mdContext || "",
        mdBlockId: parentList.attrs.mdBlockId || null,
        mdBlockSub: parentList.attrs.mdBlockSub || 0,
        mdBlockTotal: parentList.attrs.mdBlockTotal || 1,
        order: parentList.attrs.order ?? 1,
        tight: parentList.attrs.tight !== false
      } : {
        mdContext: parentList.attrs.mdContext || "",
        mdBlockId: parentList.attrs.mdBlockId || null,
        mdBlockSub: parentList.attrs.mdBlockSub || 0,
        mdBlockTotal: parentList.attrs.mdBlockTotal || 1,
        tight: parentList.attrs.tight !== false
      };
      if (parentList.type !== targetListType) {
        tr.setNodeMarkup(fromList.pos, targetListType, listAttrs);
      }
      for (const { child, pos } of touchedItems) {
        const nextTask = mode === "task" ? child.attrs.task ?? false : null;
        if (child.attrs.task !== nextTask) {
          tr.setNodeMarkup(pos, null, { ...child.attrs, task: nextTask });
        }
      }
      dispatch(tr.scrollIntoView());
      return true;
    }
    const listType = mode === "ordered" ? schema2.nodes.ordered_list : schema2.nodes.bullet_list;
    const range = $from.blockRange($to);
    if (!range) return false;
    const prepTr = state.tr;
    let convertedBlank = false;
    state.doc.nodesBetween(range.start, range.end, (node, pos) => {
      if (node.type === schema2.nodes.blank_line) {
        prepTr.setNodeMarkup(pos, schema2.nodes.paragraph, {
          mdContext: node.attrs.mdContext || "",
          mdBlockId: node.attrs.mdBlockId || null,
          mdBlockSub: node.attrs.mdBlockSub || 0,
          mdBlockTotal: node.attrs.mdBlockTotal || 1,
          mdEmpty: false
        });
        convertedBlank = true;
        return false;
      }
      return true;
    });
    if (convertedBlank) {
      const intermediateState = state.apply(prepTr);
      return wrapInList(listType, { tight: true })(intermediateState, (tr2) => {
        if (!dispatch) return;
        if (mode === "task") {
          const markFrom = Math.min(tr2.selection.from, tr2.doc.content.size);
          const markTo = Math.min(tr2.selection.to, tr2.doc.content.size);
          tr2.doc.nodesBetween(markFrom, markTo, (node, pos) => {
            if (node.type === schema2.nodes.list_item && node.attrs.task === null) {
              tr2.setNodeMarkup(pos, null, { ...node.attrs, task: false });
            }
            return true;
          });
        }
        dispatchMerged(state, [prepTr, tr2], dispatch);
      });
    }
    return wrapInList(listType, { tight: true })(state, (tr) => {
      if (!dispatch) return;
      if (mode === "task") {
        const markFrom = Math.min(tr.selection.from, tr.doc.content.size);
        const markTo = Math.min(tr.selection.to, tr.doc.content.size);
        tr.doc.nodesBetween(markFrom, markTo, (node, pos) => {
          if (node.type === schema2.nodes.list_item && node.attrs.task === null) {
            tr.setNodeMarkup(pos, null, { ...node.attrs, task: false });
          }
          return true;
        });
      }
      dispatch(tr);
    });
  }
  function insertHardBreakCommand(state, dispatch, schema2) {
    let workState = state;
    const prepTr = workState.tr;
    if (!workState.selection.empty) {
      prepTr.deleteSelection();
      workState = workState.apply(prepTr);
    }
    const { $from } = workState.selection;
    if ($from.parent.type === schema2.nodes.code_block) {
      if (dispatch) {
        const tr = prepTr.steps.length ? prepTr : state.tr;
        dispatch(tr.insertText("\n").scrollIntoView());
      }
      return true;
    }
    const ctx = insideCellOrProtected(workState, schema2);
    if (ctx.protectedAtom) return false;
    if (!ctx.inTable && $from.parent.type === schema2.nodes.heading) {
      if ($from.nodeBefore?.type === schema2.nodes.hard_break || $from.nodeAfter?.type === schema2.nodes.hard_break) {
        if (!dispatch) return true;
        const tr = prepTr.steps.length ? prepTr : state.tr;
        dispatch(tr.split($from.pos, 1, [{ type: schema2.nodes.paragraph, attrs: { mdEmpty: false } }]).scrollIntoView());
        return true;
      }
    }
    if (!ctx.inTable && $from.parent.type === schema2.nodes.blank_line) {
      if (!dispatch) return true;
      const pos = $from.pos;
      const splitTr = workState.tr.split(pos, 1, [{ type: schema2.nodes.blank_line }]);
      if (prepTr.steps.length) dispatchMerged(state, [prepTr, splitTr], dispatch);
      else dispatch(splitTr.scrollIntoView());
      return true;
    }
    const inList = !!findAncestorOfType($from, schema2.nodes.list_item);
    if (!ctx.inTable && !inList && $from.parent.type === schema2.nodes.paragraph) {
      if ($from.parentOffset === 0 && $from.depth === 1 && $from.parent.content.size > 0 && $from.nodeAfter?.type !== schema2.nodes.hard_break) {
        if (!dispatch) return true;
        const splitTr = workState.tr.insert($from.before(), schema2.nodes.blank_line.create());
        splitTr.setSelection(TextSelection.near(splitTr.doc.resolve($from.pos + 2)));
        if (prepTr.steps.length) dispatchMerged(state, [prepTr, splitTr], dispatch);
        else dispatch(splitTr.scrollIntoView());
        return true;
      }
      if ($from.nodeBefore?.type === schema2.nodes.hard_break || $from.nodeAfter?.type === schema2.nodes.hard_break) {
        let beforeBreaks = 0;
        let scanStart = $from.pos;
        while (scanStart > $from.start() && workState.doc.resolve(scanStart).nodeBefore?.type === schema2.nodes.hard_break) {
          beforeBreaks++;
          scanStart -= workState.doc.resolve(scanStart).nodeBefore.nodeSize;
        }
        let afterBreaks = 0;
        let scanEnd = $from.pos;
        while (scanEnd < $from.end() && workState.doc.resolve(scanEnd).nodeAfter?.type === schema2.nodes.hard_break) {
          afterBreaks++;
          scanEnd += workState.doc.resolve(scanEnd).nodeAfter.nodeSize;
        }
        const totalBreaks = beforeBreaks + afterBreaks;
        if (totalBreaks >= 1) {
          if (!dispatch) return true;
          const splitTr = workState.tr;
          const parent = $from.parent;
          const blockStart = $from.start();
          const blockEnd = $from.end();
          const beforeSlice = scanStart > blockStart ? workState.doc.slice(blockStart, scanStart).content : Fragment.empty;
          const afterSlice = scanEnd < blockEnd ? workState.doc.slice(scanEnd, blockEnd).content : Fragment.empty;
          const blocks = [];
          if (beforeSlice.size > 0) {
            blocks.push(schema2.nodes.paragraph.create({
              mdContext: parent.attrs.mdContext || "",
              mdBlockId: parent.attrs.mdBlockId || null,
              mdBlockSub: parent.attrs.mdBlockSub || 0,
              mdBlockTotal: parent.attrs.mdBlockTotal || 1,
              mdEmpty: false
            }, beforeSlice));
          }
          const blankCount = totalBreaks + 2 - Number(beforeSlice.size > 0) - Number(afterSlice.size > 0);
          for (let b = 0; b < blankCount; b++) {
            blocks.push(schema2.nodes.blank_line.create());
          }
          if (afterSlice.size > 0) {
            blocks.push(schema2.nodes.paragraph.create({ mdEmpty: false }, afterSlice));
          }
          splitTr.replaceWith($from.before(), $from.after(), blocks);
          let cursor = $from.before() + 1;
          for (let b = 0; b <= beforeBreaks; b++) cursor += blocks[b].nodeSize;
          splitTr.setSelection(TextSelection.create(splitTr.doc, cursor));
          if (prepTr.steps.length) dispatchMerged(state, [prepTr, splitTr], dispatch);
          else dispatch(splitTr.scrollIntoView());
          return true;
        }
      }
    }
    if (!dispatch) return true;
    const finalTr = prepTr.steps.length ? workState.tr.replaceSelectionWith(schema2.nodes.hard_break.create()) : state.tr.replaceSelectionWith(schema2.nodes.hard_break.create());
    if (prepTr.steps.length) dispatchMerged(state, [prepTr, finalTr], dispatch);
    else dispatch(finalTr.scrollIntoView());
    return true;
  }
  function clearOriginOnSplitBlock(state, dispatch, baseCommand) {
    return baseCommand(state, (tr) => {
      const newDoc = tr.doc;
      const seen = /* @__PURE__ */ new Set();
      let fix = tr;
      let offset = 0;
      newDoc.forEach((n) => {
        if (n.attrs?.mdBlockId != null && Number(n.attrs?.mdBlockTotal || 1) === 1) {
          const k = `${n.attrs.mdContext || ""}${n.attrs.mdBlockId}`;
          if (seen.has(k)) {
            fix.setNodeMarkup(offset, null, { ...n.attrs, mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 });
          } else {
            seen.add(k);
          }
        }
        offset += n.nodeSize;
      });
      dispatch(fix);
    });
  }
  function splitListItemResetTask(schema2) {
    const baseSplit = splitListItem(schema2.nodes.list_item);
    return (state, dispatch) => {
      const $from = state.selection.$from;
      const itemAnc = findAncestorOfType($from, schema2.nodes.list_item);
      if (!itemAnc || itemAnc.node.attrs.task !== true) {
        return baseSplit(state, dispatch);
      }
      return baseSplit(state, (tr) => {
        if (!dispatch) return;
        const { $from: nextFrom } = tr.selection;
        const newAnc = findAncestorOfType(nextFrom, schema2.nodes.list_item);
        if (newAnc && newAnc.node.attrs.task === true) {
          tr.setNodeMarkup(newAnc.pos, null, { ...newAnc.node.attrs, task: false });
        }
        dispatch(tr);
      });
    };
  }
  function buildEnterCommand(schema2 = schema) {
    return chainCommands(
      newlineInCode,
      splitListItemResetTask(schema2),
      (state, dispatch) => {
        const { $from, empty: empty2 } = state.selection;
        if (!empty2) return false;
        const parent = $from.parent;
        if (parent.type === schema2.nodes.blank_line) {
          if (!dispatch) return true;
          const pos = $from.before();
          const tr = state.tr.insert($from.after(), schema2.nodes.blank_line.create());
          tr.setSelection(TextSelection.near(tr.doc.resolve(pos + parent.nodeSize + 1)));
          dispatch(tr.scrollIntoView());
          return true;
        }
        if (parent.type === schema2.nodes.paragraph && parent.content.size > 0 && $from.parentOffset === 0 && $from.depth === 1) {
          if (!dispatch) return true;
          const pos = $from.before();
          const blank = schema2.nodes.blank_line.create();
          const tr = state.tr.insert(pos, blank);
          tr.setSelection(TextSelection.near(tr.doc.resolve(pos + blank.nodeSize + 1)));
          dispatch(tr.scrollIntoView());
          return true;
        }
        if (parent.type === schema2.nodes.paragraph && parent.content.size === 0 && $from.depth === 1) {
          if (!dispatch) return true;
          const pos = $from.before();
          const tr = state.tr;
          tr.setNodeMarkup(pos, schema2.nodes.blank_line, {
            mdContext: parent.attrs.mdContext || "",
            mdBlockId: parent.attrs.mdBlockId || null,
            mdBlockSub: parent.attrs.mdBlockSub || 0,
            mdBlockTotal: parent.attrs.mdBlockTotal || 1
          });
          tr.insert(pos + parent.nodeSize, schema2.nodes.paragraph.create({ mdEmpty: false }));
          tr.setSelection(TextSelection.near(tr.doc.resolve(pos + parent.nodeSize + 1)));
          dispatch(tr.scrollIntoView());
          return true;
        }
        return false;
      },
      (s, d) => d ? clearOriginOnSplitBlock(s, d, createParagraphNear) : createParagraphNear(s),
      liftEmptyBlock,
      (s, d) => d ? clearOriginOnSplitBlock(s, d, splitBlock) : splitBlock(s)
    );
  }
  function buildInputRules(schema2 = schema) {
    const wrapParagraphAsList = (state, start, end, listType, listAttrs, itemAttrs) => {
      const $start = state.doc.resolve(start);
      if ($start.parent.type !== schema2.nodes.paragraph && $start.parent.type !== schema2.nodes.blank_line) return null;
      if ($start.start() !== start) return null;
      if (findAncestorOfType($start, schema2.nodes.list_item)) return null;
      const tr = state.tr.delete(start, end);
      const blockPos = tr.mapping.map($start.before());
      if (tr.doc.nodeAt(blockPos)?.type === schema2.nodes.blank_line) {
        const bn = tr.doc.nodeAt(blockPos);
        tr.setNodeMarkup(blockPos, schema2.nodes.paragraph, {
          mdContext: bn.attrs.mdContext || "",
          mdBlockId: bn.attrs.mdBlockId || null,
          mdBlockSub: bn.attrs.mdBlockSub || 0,
          mdBlockTotal: bn.attrs.mdBlockTotal || 1,
          mdEmpty: false
        });
      }
      const $resolved = tr.doc.resolve(blockPos + 1);
      const range = $resolved.blockRange();
      if (!range) return null;
      const wrappers = findWrapping(range, listType, listAttrs);
      if (!wrappers) return null;
      tr.wrap(range, wrappers);
      return tr;
    };
    const rules = [
      new InputRule(
        /^([-+*])\s$/,
        (state, _match, start, end) => wrapParagraphAsList(state, start, end, schema2.nodes.bullet_list, { tight: true }, { task: null })
      ),
      new InputRule(
        /^(\d{1,9})\.\s$/,
        (state, match, start, end) => wrapParagraphAsList(
          state,
          start,
          end,
          schema2.nodes.ordered_list,
          { order: Number(match[1]), tight: true },
          { task: null }
        )
      ),
      new InputRule(/^(#{1,6})\s$/, (state, match, start, end) => {
        const $start = state.doc.resolve(start);
        if ($start.parent.type !== schema2.nodes.paragraph && $start.parent.type !== schema2.nodes.blank_line) return null;
        if ($start.start() !== start) return null;
        const level = match[1].length;
        const tr = state.tr.delete(start, end);
        tr.setNodeMarkup($start.before(), schema2.nodes.heading, {
          ...$start.parent.attrs,
          level,
          outlineIgnore: false
        });
        return tr;
      }),
      new InputRule(/^>\s$/, (state, _match, start, end) => {
        const $start = state.doc.resolve(start);
        if ($start.parent.type !== schema2.nodes.paragraph && $start.parent.type !== schema2.nodes.blank_line) return null;
        if ($start.start() !== start) return null;
        const tr = state.tr.delete(start, end);
        const mappedState = state.apply(tr);
        let wrapTr = null;
        wrapIn(schema2.nodes.blockquote)(mappedState, (t) => {
          wrapTr = t;
        });
        if (!wrapTr) return null;
        const combined = state.tr;
        for (const s of tr.steps) combined.step(s);
        for (const s of wrapTr.steps) combined.step(s);
        if (wrapTr.selectionSet) combined.setSelection(Selection.fromJSON(combined.doc, wrapTr.selection.toJSON()));
        return combined;
      })
    ];
    return inputRules({ rules });
  }
  function buildKeymap({
    schema: schema2 = schema,
    getTableEditor,
    isBlocked,
    onHardBreak,
    onTabFallback,
    onUndo,
    onRedo
  }) {
    function deleteInDirection(key, direction) {
      return (state, dispatch, view) => {
        if (isBlocked()) return true;
        const { $from, $to, empty: empty2 } = state.selection;
        const table = insideCellOrProtected(state, schema2);
        if (table.inTable && !$from.sameParent($to)) return true;
        if (empty2) {
          const adjacent = ($pos) => direction < 0 ? $pos.nodeBefore : $pos.nodeAfter;
          const atEdge = direction < 0 ? $from.parentOffset === 0 : $from.parentOffset === $from.parent.content.size;
          if (atEdge && table.inTable) return true;
          if (!$from.parent.isTextblock && adjacent($from)?.isAtom && NodeSelection.isSelectable(adjacent($from))) {
            const pos = direction < 0 ? $from.pos - adjacent($from).nodeSize : $from.pos;
            if (dispatch) dispatch(state.tr.setSelection(NodeSelection.create(state.doc, pos)));
            return true;
          }
          if (atEdge && $from.depth > 0) {
            const boundary = state.doc.resolve(direction < 0 ? $from.before() : $from.after());
            const type = adjacent(boundary)?.type;
            if (type === schema2.nodes.math_block || type === schema2.nodes.opaque_block) {
              return (direction < 0 ? selectNodeBackward : selectNodeForward)(state, dispatch, view);
            }
          }
        }
        return baseKeymap[key](state, dispatch, view);
      };
    }
    const backspace2 = deleteInDirection("Backspace", -1);
    const deleteForward = deleteInDirection("Delete", 1);
    return keymap({
      Enter: buildEnterCommand(schema2),
      Backspace: backspace2,
      "Mod-Backspace": backspace2,
      "Shift-Backspace": backspace2,
      Delete: deleteForward,
      "Mod-Delete": deleteForward,
      "Shift-Enter": (state, dispatch) => {
        if (isBlocked()) return true;
        if (onHardBreak) return onHardBreak(state, dispatch);
        return insertHardBreakCommand(state, dispatch ? (tr) => dispatch(closeHistory(tr)) : null, schema2);
      },
      "Alt-Enter": (state, dispatch) => {
        if (isBlocked()) return true;
        if (onHardBreak) return onHardBreak(state, dispatch);
        return insertHardBreakCommand(state, dispatch ? (tr) => dispatch(closeHistory(tr)) : null, schema2);
      },
      "Shift-Alt-Enter": (state, dispatch) => {
        if (isBlocked()) return true;
        if (onHardBreak) return onHardBreak(state, dispatch);
        return insertHardBreakCommand(state, dispatch ? (tr) => dispatch(closeHistory(tr)) : null, schema2);
      },
      Tab: (state, dispatch) => {
        if (isBlocked()) return true;
        const tables = getTableEditor?.();
        if (tables?.context?.() && tables.navigate?.(false)) return true;
        if (sinkListItem(schema2.nodes.list_item)(state, dispatch)) return true;
        if (findAncestorOfType(state.selection.$from, schema2.nodes.list_item)) return true;
        if (state.selection.$from.parent.type === schema2.nodes.code_block) {
          if (dispatch) dispatch(state.tr.insertText("	").scrollIntoView());
          return true;
        }
        if (onTabFallback) return onTabFallback(state, dispatch);
        if (dispatch) dispatch(state.tr.insertText("\xA0\xA0\xA0\xA0").scrollIntoView());
        return true;
      },
      "Shift-Tab": (state, dispatch) => {
        if (isBlocked()) return true;
        const tables = getTableEditor?.();
        if (tables?.context?.() && tables.navigate?.(true)) return true;
        return liftListItem(schema2.nodes.list_item)(state, dispatch);
      },
      "Mod-z": () => {
        if (isBlocked()) return true;
        return onUndo ? onUndo() : false;
      },
      "Mod-Shift-z": () => {
        if (isBlocked()) return true;
        return onRedo ? onRedo() : false;
      },
      "Mod-y": () => {
        if (isBlocked()) return true;
        return onRedo ? onRedo() : false;
      }
    });
  }
  function executeVisualCommand(view, command, value, {
    schema: schema2 = schema,
    tableEditor,
    postMessage,
    session,
    onHistoryCommand
  } = {}) {
    if (command === "undo" || command === "redo") {
      const ok = onHistoryCommand ? onHistoryCommand(command) : (command === "undo" ? undo : redo)(view.state, (tr) => view.dispatch(tr));
      return { executed: !!ok, changed: !!ok, reason: ok ? void 0 : "empty-history" };
    }
    const { state } = view;
    const ctx = insideCellOrProtected(state, schema2);
    if ((ctx.protectedAtom || ctx.containsProtected) && command !== "deleteImage" && command !== "delete") {
      postMessage?.({ kind: "protectedFormat", session });
      return { executed: false, changed: false, reason: "protected" };
    }
    const blockLevelCommands = /* @__PURE__ */ new Set([
      "heading1",
      "heading2",
      "heading3",
      "heading4",
      "heading5",
      "heading6",
      "bulletList",
      "orderedList",
      "taskList",
      "quote",
      "insertTable"
    ]);
    if (ctx.inTable && blockLevelCommands.has(command)) {
      tableEditor?.syncToolbar?.();
      postMessage?.({ kind: "tableError", session, reason: "format" });
      return { executed: false, changed: false, reason: "table" };
    }
    let didChange = false;
    const dispatch = (tr) => {
      const withBoundary = command === "insertText" ? tr : closeHistory(tr);
      if (withBoundary.docChanged || withBoundary.storedMarksSet) didChange = true;
      view.dispatch(withBoundary);
    };
    let handled = false;
    switch (command) {
      case "deleteImage": {
        const sel = state.selection;
        if (sel instanceof NodeSelection && sel.node.type === schema2.nodes.image) {
          dispatch(state.tr.deleteSelection().scrollIntoView());
          handled = true;
        } else {
          const after = sel.$from.nodeAfter;
          if (after && after.type === schema2.nodes.image) {
            dispatch(state.tr.delete(sel.from, sel.from + after.nodeSize).scrollIntoView());
            handled = true;
          }
        }
        break;
      }
      case "heading1":
      case "heading2":
      case "heading3":
      case "heading4":
      case "heading5":
      case "heading6": {
        const res = applyHeadingOrParagraph(state, dispatch, schema2, { level: Number(command.slice(7)) });
        return { executed: res.handled, changed: res.changed, reason: res.reason };
      }
      case "plainParagraph": {
        const res = applyHeadingOrParagraph(state, dispatch, schema2, { level: null });
        return { executed: res.handled, changed: res.changed, reason: res.reason };
      }
      case "bulletList":
        handled = toggleListMode(state, dispatch, schema2, "bullet");
        break;
      case "orderedList":
        handled = toggleListMode(state, dispatch, schema2, "ordered");
        break;
      case "taskList":
        handled = toggleListMode(state, dispatch, schema2, "task");
        break;
      case "quote": {
        if (unwrapBlockquote(state, dispatch, schema2)) {
          handled = true;
          break;
        }
        const { $from, $to } = state.selection;
        const listAnc = findNearestListAncestor($from, schema2);
        if (listAnc && $to.depth >= listAnc.depth && $to.before(listAnc.depth) === listAnc.pos) {
          const range = state.doc.resolve(listAnc.pos).blockRange(state.doc.resolve(listAnc.pos + listAnc.node.nodeSize));
          const wrapping = range && findWrapping(range, schema2.nodes.blockquote);
          if (wrapping) {
            dispatch(state.tr.wrap(range, wrapping).scrollIntoView());
            handled = true;
            break;
          }
        }
        handled = wrapIn(schema2.nodes.blockquote)(state, dispatch);
        break;
      }
      case "hardBreak":
        handled = insertHardBreakCommand(state, dispatch, schema2);
        break;
      case "insertParagraph":
        handled = buildEnterCommand(schema2)(state, dispatch);
        break;
      case "delete":
        if (!state.selection.empty) {
          const tr = state.tr.deleteSelection().scrollIntoView();
          if (tr.doc.childCount === 1 && (tr.doc.firstChild.type === schema2.nodes.paragraph || tr.doc.firstChild.type === schema2.nodes.blank_line) && tr.doc.firstChild.content.size === 0) {
            tr.setNodeMarkup(0, schema2.nodes.paragraph, {
              ...tr.doc.firstChild.attrs,
              mdContext: "",
              mdBlockId: null,
              mdBlockSub: 0,
              mdBlockTotal: 1,
              mdEmpty: false,
              mdDeleted: true
            });
          }
          dispatch(tr);
          handled = true;
        }
        break;
      case "insertText": {
        const text = String(value ?? "");
        dispatch(state.tr.insertText(text).scrollIntoView());
        handled = true;
        break;
      }
      case "bold":
        handled = toggleMark(schema2.marks.strong)(state, dispatch);
        break;
      case "italic":
        handled = toggleMark(schema2.marks.em)(state, dispatch);
        break;
      case "code": {
        const codeMark = schema2.marks.code;
        if (state.selection.empty) {
          handled = toggleMark(codeMark)(state, dispatch);
        } else {
          const { from: from2, to } = state.selection;
          let hasText = false;
          let hasActiveCode = false;
          state.doc.nodesBetween(from2, to, (node) => {
            if (node.isText) {
              hasText = true;
              if (codeMark.isInSet(node.marks)) hasActiveCode = true;
            }
            return true;
          });
          if (!hasText) {
            return { executed: false, changed: false, reason: "protected" };
          }
          const tr = state.tr;
          if (hasActiveCode) {
            tr.removeMark(from2, to, codeMark);
          } else {
            state.doc.nodesBetween(from2, to, (node, pos) => {
              if (!node.isText) return true;
              const segFrom = Math.max(from2, pos);
              const segTo = Math.min(to, pos + node.nodeSize);
              if (segFrom < segTo) tr.addMark(segFrom, segTo, codeMark.create());
              return true;
            });
          }
          if (tr.docChanged) {
            dispatch(tr.scrollIntoView());
            handled = true;
          }
        }
        break;
      }
      case "highlight":
        handled = toggleMark(schema2.marks.highlight)(state, dispatch);
        break;
      case "strike":
        handled = toggleMark(schema2.marks.strike)(state, dispatch);
        break;
      case "link": {
        const href = typeof value === "string" ? value.trim() : "";
        if (!href) {
          if (isMarkActive(state, schema2.marks.link)) {
            const { from: from2, to, empty: empty2 } = state.selection;
            if (!empty2) dispatch(state.tr.removeMark(from2, to, schema2.marks.link));
            else dispatch(state.tr.removeStoredMark(schema2.marks.link));
            handled = true;
          }
        } else {
          const { from: from2, to, empty: empty2 } = state.selection;
          const mark = schema2.marks.link.create({ href, title: null });
          if (empty2) {
            dispatch(state.tr.addStoredMark(mark));
            handled = true;
          } else {
            dispatch(state.tr.addMark(from2, to, mark));
            handled = true;
          }
        }
        break;
      }
      case "insertTable": {
        const result = tableEditor?.insertTable(value?.rows, value?.columns);
        if (result && !result.ok) postMessage?.({ kind: "tableError", session, reason: result.reason });
        return { executed: result?.ok === true, changed: result?.ok === true, reason: "table" };
      }
      case "insertHTML": {
        const ownerDocument = view.dom.ownerDocument;
        const html = sanitizePasteHTML(String(value || ""), ownerDocument);
        const nodes2 = parseHTMLToNodes(html, { schema: schema2, ownerDocument });
        if (nodes2.length) {
          const slice2 = new Slice(Fragment.fromArray(nodes2), 0, 0);
          dispatch(state.tr.replaceSelection(slice2).scrollIntoView());
          handled = true;
        }
        break;
      }
      default:
        handled = false;
        break;
    }
    return { executed: handled, changed: didChange };
  }
  function getHistoryState(state) {
    const uDepth = undoDepth(state);
    const rDepth = redoDepth(state);
    return {
      canUndo: uDepth > 0,
      canRedo: rDepth > 0,
      undoDepth: uDepth,
      redoDepth: rDepth
    };
  }

  // src/diagnostics.js
  var DIAGNOSTIC_MAX_EVENTS = 200;
  var DIAGNOSTIC_MAX_BYTES = 262144;
  var ALLOWED_ANOMALY_FIELDS = /* @__PURE__ */ new Set([
    "command",
    "beforeTextLen",
    "afterTextLen",
    "lineno",
    "colno",
    "reason",
    "outcome",
    "offset"
  ]);
  var ALLOWED_EVENT_FIELDS = /* @__PURE__ */ new Set([
    "command",
    "beforeTextLen",
    "afterTextLen",
    "key",
    "meta",
    "ctrl",
    "shift",
    "alt",
    "blockCount",
    "markdownLen",
    "empty",
    "code",
    "lineno",
    "colno",
    "sel"
  ]);
  var ALLOWED_KEY_NAMES = /* @__PURE__ */ new Set([
    "Enter",
    "Backspace",
    "Delete",
    "Tab",
    "Escape",
    "ArrowLeft",
    "ArrowRight",
    "ArrowUp",
    "ArrowDown",
    "Home",
    "End",
    "PageUp",
    "PageDown",
    "Shift",
    "Control",
    "Alt",
    "Meta"
  ]);
  var ALLOWED_SHORTCUT_KEYS = /* @__PURE__ */ new Set(["a", "b", "c", "i", "k", "u", "v", "x", "y", "z"]);
  function sanitizeDiagnosticKey(key, hasModifier) {
    if (typeof key !== "string" || !key.length) return "unknown";
    if (ALLOWED_KEY_NAMES.has(key)) return key;
    if (hasModifier && ALLOWED_SHORTCUT_KEYS.has(key.toLowerCase())) return key.toLowerCase();
    return "char";
  }
  function semanticBlockTag(tagName) {
    switch (tagName) {
      case "H1":
      case "H2":
      case "H3":
      case "H4":
      case "H5":
      case "H6":
      case "UL":
      case "OL":
      case "LI":
      case "BLOCKQUOTE":
      case "PRE":
      case "TABLE":
      case "HR":
        return tagName;
      case "P":
      case "DIV":
        return "P";
      default:
        return null;
    }
  }
  function emptyPMOrDOMPlaceholder(container) {
    if (!container) return null;
    const children = Array.from(container.children).filter(
      (n) => !n.hasAttribute("data-md-edit-boundary") && !n.classList.contains("ProseMirror-separator")
    );
    if (children.length !== 1) return null;
    const node = children[0];
    if (!node.hasAttribute("data-md-empty") || node.textContent.replace(/\u200b/g, "").length > 0 || node.querySelector("img:not(.ProseMirror-separator),input,hr,table,pre,code,[data-md-opaque],[data-tex]") || Array.from(container.childNodes).some((n) => n.nodeType === 3 && n.data.trim())) {
      return null;
    }
    return node;
  }
  function deletedDocumentPlaceholder(container, _inputType) {
    const visible = Array.from(container.children).filter(
      (n) => !n.hasAttribute("data-md-edit-boundary") && !n.classList.contains("ProseMirror-separator")
    );
    return visible.length === 1 && visible[0].tagName === "P" && !visible[0].textContent.replace(/\u200b/g, "").length && !Array.from(container.childNodes).some((n) => n.nodeType === 3 && n.data.trim()) && visible[0].querySelectorAll("br").length <= 1 && !visible[0].querySelector("img:not(.ProseMirror-separator),input,hr,table,pre,code,[data-md-opaque],[data-tex]") ? visible[0] : null;
  }
  function saveAppearance(container, inputType = "") {
    const placeholder = emptyPMOrDOMPlaceholder(container) || deletedDocumentPlaceholder(container, inputType);
    const blockSet = /^(DIV|P|SECTION|H[1-6]|UL|OL|LI|BLOCKQUOTE|TABLE|THEAD|TBODY|TFOOT|TR|TD|TH|PRE|HR)$/;
    const tags = { B: 1, STRONG: 1, I: 2, EM: 2, MARK: 4, DEL: 8, S: 8, STRIKE: 8, CODE: 16 };
    let text = "";
    let space = false;
    let spaceHref = null;
    let pendingBreaks = 0;
    let totalBreaks = 0;
    const formats = [];
    const breaks = [];
    const blockTypes = [];
    const links = [];
    const tasks = [];
    const listStarts = [];
    function recordBreaks(count) {
      if (!count) return;
      if (breaks.at(-1)?.[0] === text.length) breaks.at(-1)[1] += count;
      else breaks.push([text.length, count]);
      totalBreaks += count;
    }
    function boundary() {
      if (pendingBreaks > 0) {
        recordBreaks(pendingBreaks);
      }
      pendingBreaks = 0;
      space = !!text;
      spaceHref = null;
    }
    function addText(value, style, href) {
      for (const word of String(value || "").replace(/\u200b/g, "").match(/[^ \t\r\n\f]+|[ \t\r\n\f]+/g) || []) {
        if (/^[ \t\r\n\f]/.test(word)) {
          if (!space) spaceHref = href;
          space = !!text;
          continue;
        }
        if (pendingBreaks) {
          recordBreaks(pendingBreaks);
          pendingBreaks = 0;
          space = !!text;
          spaceHref = null;
        }
        if (space) {
          text += " ";
          space = false;
        }
        const start = text.length;
        text += word;
        if (href !== null) {
          const previous = links.at(-1);
          if (previous?.[2] === href && (previous[1] === start || spaceHref === href && previous[1] === start - 1)) {
            previous[1] = text.length;
          } else {
            links.push([start, text.length, href]);
          }
        }
        spaceHref = null;
        if (style) {
          const previous = formats.at(-1);
          if (previous?.[1] === start && previous[2] === style) previous[1] = text.length;
          else formats.push([start, text.length, style]);
        }
      }
    }
    function visit(node, style, tableCell = false, href = null) {
      if (node.nodeType === 3) {
        if (tableCell) {
          node.data.split(/\r\n?|\n/).forEach((part, index) => {
            if (index) pendingBreaks++;
            addText(part, style, href);
          });
        } else {
          addText(node.data, style, href);
        }
        return;
      }
      if (node.nodeType !== 1 || node === placeholder || node.hasAttribute("data-md-edit-boundary") || node.classList?.contains("ProseMirror-separator") || node.classList?.contains("ProseMirror-trailingBreak")) {
        return;
      }
      const tag = node.tagName;
      const isBlock = blockSet.test(tag);
      if (tag === "INPUT" && node.type === "checkbox") {
        tasks.push(!!(node.checked || node.hasAttribute("checked")));
        return;
      }
      if (tag === "OL") {
        const startAttr = node.getAttribute("start")?.trim();
        listStarts.push(startAttr && /^[+-]?\d+$/.test(startAttr) ? Number(startAttr) : 1);
      }
      if (tag === "A" && node.hasAttribute("href")) {
        href = node.getAttribute("href").replace(/[ \u0080-\uD7FF\uE000-\u{10FFFF}]/gu, encodeURIComponent);
      }
      if (node.classList?.contains("fastra-pm-li-content") || tag === "DIV" && node.classList?.contains("ProseMirror")) {
        for (const child of node.childNodes) visit(child, style, tableCell, href);
        return;
      }
      if (node.hasAttribute("data-tex") || node.hasAttribute("data-md-opaque")) {
        if (isBlock) boundary();
        addText("\uFFFC", style, href);
        if (isBlock) boundary();
        return;
      }
      if (tag === "DIV" && node.classList?.contains("fastra-visible-blank-line")) {
        boundary();
        const emptyBlank = !node.textContent.replace(/\u200b/g, "").length && !node.querySelector("img:not(.ProseMirror-separator),[data-tex],[data-md-opaque],hr,table,pre,input");
        if (emptyBlank) {
          recordBreaks(1);
          boundary();
          return;
        }
      }
      if (tag === "BR") {
        pendingBreaks++;
        return;
      }
      if (isBlock) {
        boundary();
        const semantic = semanticBlockTag(tag);
        const liParent = tag === "P" ? node.closest?.("li") : null;
        const cellParent = tag === "P" ? node.closest?.("td,th") : null;
        const emptyTopParagraph = tag === "P" && !liParent && !cellParent && !node.textContent.replace(/[\u200b \t\r\n\f]/g, "").length && !node.querySelector("img:not(.ProseMirror-separator),[data-tex],[data-md-opaque],hr,table,pre,input,br:not(.ProseMirror-trailingBreak)");
        if (emptyTopParagraph) {
          recordBreaks(1);
          boundary();
          return;
        }
        if (semantic && !liParent && !(tag === "DIV" && (node.classList.contains("fastra-visible-blank-line") || node.hasAttribute("data-md-block")))) {
          blockTypes.push(semantic);
        }
      }
      const before = text.length;
      const breakCount = totalBreaks;
      if (tag === "IMG") {
        addText("\uFFFC", style, href);
      } else {
        let nextStyle = style | (tags[tag] || 0);
        if (tag === "SPAN" || tag === "FONT") {
          const css = node.style;
          if (css?.fontWeight === "bold" || Number(css?.fontWeight) >= 600) nextStyle |= 1;
          if (css?.fontStyle === "italic" || css?.fontStyle === "oblique") nextStyle |= 2;
          if (css?.backgroundColor && css.backgroundColor !== "transparent" && css.backgroundColor !== "rgba(0, 0, 0, 0)") nextStyle |= 4;
          if (css?.textDecorationLine?.includes("line-through")) nextStyle |= 8;
        }
        const preWrap = tableCell || (tag === "TD" || tag === "TH") && !!node.closest("table[data-md-table=gfm]");
        for (const child of node.childNodes) visit(child, nextStyle, preWrap, href);
      }
      if (isBlock) {
        if (text.length === before && totalBreaks === breakCount && pendingBreaks) {
          const emptyLineBreaks = /^H[1-6]$/.test(tag) || tag === "LI" ? Math.max(0, pendingBreaks - 1) : pendingBreaks;
          recordBreaks(emptyLineBreaks);
          pendingBreaks = 0;
        }
        boundary();
      }
    }
    for (const node of container.childNodes) visit(node, 0, false);
    boundary();
    return { text, formats, breaks, blockTypes, links, tasks, listStarts };
  }
  function sameLinks(live, saved) {
    const liveLinks = live.links || [];
    let next = 0;
    for (const [start, end, href] of saved.links || []) {
      const current = liveLinks[next];
      if (current?.[0] === start && current[1] === end && current[2] === href) {
        next++;
        continue;
      }
      const address = saved.text.slice(start, end).replace(/^mailto:/, "");
      if (current && current[0] < end || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address) || href !== `mailto:${address}`) {
        return false;
      }
    }
    return next === liveLinks.length;
  }
  function diffAppearance(live, saved, { includeContent = true } = {}) {
    if (live.text !== saved.text) {
      let at = 0;
      const minLen = Math.min(live.text.length, saved.text.length);
      while (at < minLen && live.text[at] === saved.text[at]) at++;
      const diff = {
        offset: at,
        liveLength: live.text.length,
        savedLength: saved.text.length
      };
      if (includeContent) {
        diff.liveSnippet = live.text.slice(Math.max(0, at - 20), at + 40);
        diff.savedSnippet = saved.text.slice(Math.max(0, at - 20), at + 40);
      }
      return { outcome: "text", diff };
    }
    if (JSON.stringify(live.formats) !== JSON.stringify(saved.formats)) {
      return {
        outcome: "format",
        diff: {
          liveCount: live.formats.length,
          savedCount: saved.formats.length,
          liveFormats: live.formats.slice(0, 12),
          savedFormats: saved.formats.slice(0, 12)
        }
      };
    }
    if (JSON.stringify(live.blockTypes) !== JSON.stringify(saved.blockTypes)) {
      return {
        outcome: "format",
        diff: {
          liveBlockCount: live.blockTypes.length,
          savedBlockCount: saved.blockTypes.length,
          liveBlocks: live.blockTypes.slice(0, 24),
          savedBlocks: saved.blockTypes.slice(0, 24)
        }
      };
    }
    if (!sameLinks(live, saved)) {
      return {
        outcome: "format",
        diff: {
          kind: "links",
          liveCount: (live.links || []).length,
          savedCount: (saved.links || []).length
        }
      };
    }
    if (JSON.stringify(live.tasks || []) !== JSON.stringify(saved.tasks || [])) {
      return {
        outcome: "format",
        diff: {
          kind: "tasks",
          liveCount: (live.tasks || []).length,
          savedCount: (saved.tasks || []).length,
          liveTasks: (live.tasks || []).slice(0, 24),
          savedTasks: (saved.tasks || []).slice(0, 24)
        }
      };
    }
    if (JSON.stringify(live.listStarts || []) !== JSON.stringify(saved.listStarts || [])) {
      return {
        outcome: "format",
        diff: {
          kind: "listStarts",
          liveStarts: (live.listStarts || []).slice(0, 24),
          savedStarts: (saved.listStarts || []).slice(0, 24)
        }
      };
    }
    if (JSON.stringify(live.breaks) !== JSON.stringify(saved.breaks)) {
      return {
        outcome: "breaks",
        diff: {
          liveCount: live.breaks.length,
          savedCount: saved.breaks.length,
          liveBreaks: live.breaks.slice(0, 12),
          savedBreaks: saved.breaks.slice(0, 12)
        }
      };
    }
    return { outcome: "ok", diff: null };
  }
  function redactDiff(diff, includeContent) {
    if (!diff || includeContent) return diff;
    const copy2 = { ...diff };
    delete copy2.liveSnippet;
    delete copy2.savedSnippet;
    return copy2;
  }
  function sanitizeFields(source, allowedSet) {
    const out = {};
    for (const [k, v] of Object.entries(source || {})) {
      if (allowedSet.has(k)) out[k] = v;
    }
    return out;
  }
  function createDiagnosticsController({
    postMessage,
    getSession,
    getRevision,
    getRoot,
    isFenced,
    isComposing,
    getLastInputType,
    serializeMarkdown
  }) {
    const diagnosticEvents = [];
    const diagnosticAnomalies = [];
    let diagnosticBytes = 0;
    let lastAppearanceCheck = null;
    let lastRenderedHTML = null;
    function visibleTextLength(container = getRoot()) {
      if (!container) return 0;
      const clone = container.cloneNode(true);
      clone.querySelectorAll("[data-md-edit-boundary]").forEach((n) => n.remove());
      return (clone.textContent || "").replace(/[\u200b\u2060\r\n]/g, "").length;
    }
    function selectionSummary(view) {
      if (!view) return null;
      const { from: from2, to, empty: empty2 } = view.state.selection;
      return { collapsed: empty2, from: from2, to };
    }
    function domSkeleton(container = getRoot(), depth = 0) {
      if (!container || depth > 5) return null;
      const children = [];
      for (const child of Array.from(container.children).slice(0, 40)) {
        if (child.hasAttribute("data-md-edit-boundary")) continue;
        const entry = { tag: child.tagName.toLowerCase() };
        if (child.classList.contains("fastra-visible-blank-line")) entry.blank = true;
        if (child.hasAttribute("data-md-empty")) entry.empty = true;
        if (child.hasAttribute("data-md-opaque")) entry.opaque = true;
        if (child.hasAttribute("data-tex")) entry.math = true;
        if (child.tagName === "INPUT" && child.type === "checkbox") entry.checkbox = !!child.checked;
        if (child.children.length && !entry.opaque && !entry.math) {
          entry.children = domSkeleton(child, depth + 1);
        }
        children.push(entry);
      }
      return children;
    }
    function pushDiagnosticEvent(kind, details = {}) {
      const entry = { t: (/* @__PURE__ */ new Date()).toISOString(), kind, rev: getRevision(), ...details };
      const size = JSON.stringify(entry).length + 2;
      diagnosticEvents.push(entry);
      diagnosticBytes += size;
      while (diagnosticEvents.length > DIAGNOSTIC_MAX_EVENTS || diagnosticBytes > DIAGNOSTIC_MAX_BYTES) {
        const removed = diagnosticEvents.shift();
        diagnosticBytes -= removed ? JSON.stringify(removed).length + 2 : 0;
      }
    }
    function recordAnomaly(code, summary, extra = {}) {
      const sanitizedExtra = sanitizeFields(extra, ALLOWED_ANOMALY_FIELDS);
      const entry = {
        t: (/* @__PURE__ */ new Date()).toISOString(),
        code,
        rev: getRevision(),
        ...sanitizedExtra
      };
      const redactionSafeSummary = `${code}${sanitizedExtra.command ? `:${sanitizedExtra.command}` : ""}`;
      entry._fullSummary = String(summary || redactionSafeSummary);
      entry.summary = redactionSafeSummary;
      diagnosticAnomalies.push(entry);
      if (diagnosticAnomalies.length > 50) diagnosticAnomalies.shift();
      pushDiagnosticEvent("anomaly", { code, ...sanitizedExtra });
      try {
        postMessage({
          kind: "diagnosticAnomaly",
          session: getSession(),
          revision: getRevision(),
          code,
          summary: redactionSafeSummary
        });
      } catch (_) {
      }
    }
    function compareSave(html) {
      lastRenderedHTML = html;
      const candidate = document.createElement("template");
      candidate.innerHTML = html;
      const live = saveAppearance(getRoot(), getLastInputType());
      const saved = saveAppearance(candidate.content);
      const comparison = diffAppearance(live, saved, { includeContent: true });
      lastAppearanceCheck = {
        revision: getRevision(),
        at: (/* @__PURE__ */ new Date()).toISOString(),
        source: "save",
        ...comparison
      };
      return comparison.outcome;
    }
    function inspect(html) {
      lastRenderedHTML = html;
      const candidate = document.createElement("template");
      candidate.innerHTML = html;
      const live = saveAppearance(getRoot(), getLastInputType());
      const saved = saveAppearance(candidate.content);
      const comparison = diffAppearance(live, saved, { includeContent: false });
      lastAppearanceCheck = {
        revision: getRevision(),
        at: (/* @__PURE__ */ new Date()).toISOString(),
        source: "live",
        ...diffAppearance(live, saved, { includeContent: true })
      };
      return {
        outcome: comparison.outcome,
        diff: comparison.diff,
        revision: getRevision(),
        anomalies: diagnosticAnomalies.slice(-10).map((a) => formatAnomaly(a, false))
      };
    }
    function formatAnomaly(a, includeContent) {
      const base2 = {
        t: a.t,
        code: a.code,
        rev: a.rev,
        summary: includeContent ? a._fullSummary || a.summary : a.summary,
        ...sanitizeFields(a, ALLOWED_ANOMALY_FIELDS)
      };
      return base2;
    }
    function formatEvent(e, includeContent) {
      const out = { t: e.t, kind: e.kind, rev: e.rev };
      for (const [k, v] of Object.entries(e)) {
        if (k === "t" || k === "kind" || k === "rev") continue;
        if (includeContent || ALLOWED_EVENT_FIELDS.has(k)) {
          if (!includeContent && e.kind === "keydown" && k === "key") {
            out[k] = sanitizeDiagnosticKey(v, !!(e.meta || e.ctrl));
          } else {
            out[k] = v;
          }
        }
      }
      return out;
    }
    function report(includeContent = false) {
      const markdown = serializeMarkdown();
      const out = {
        session: getSession(),
        revision: getRevision(),
        fenced: isFenced(),
        composing: isComposing(),
        lastInputType: getLastInputType(),
        visibleTextLength: visibleTextLength(),
        markdownLength: markdown.length,
        lastAppearanceCheck: lastAppearanceCheck ? {
          revision: lastAppearanceCheck.revision,
          at: lastAppearanceCheck.at,
          source: lastAppearanceCheck.source,
          outcome: lastAppearanceCheck.outcome,
          diff: redactDiff(lastAppearanceCheck.diff, includeContent)
        } : null,
        anomalies: diagnosticAnomalies.map((a) => formatAnomaly(a, includeContent)),
        events: diagnosticEvents.map((e) => formatEvent(e, includeContent)),
        domSkeleton: domSkeleton(getRoot())
      };
      if (includeContent) {
        out.liveHTML = getRoot()?.innerHTML || "";
        out.serializedMarkdown = markdown;
        out.lastRenderedHTML = lastRenderedHTML;
      }
      return out;
    }
    return {
      visibleTextLength,
      selectionSummary,
      domSkeleton,
      pushDiagnosticEvent,
      recordAnomaly,
      compareSave,
      inspect,
      report
    };
  }

  // src/tables.js
  var maxRows = 1e3;
  var maxColumns = 100;
  var maxCells = 1e4;
  var maxBytes = 1048576;
  var encoder = new TextEncoder();
  var alignments = ["none", "left", "center", "right"];
  var hostCommands = /* @__PURE__ */ new Map([
    ["rowBefore", "insertRowBefore"],
    ["rowAfter", "insertRowAfter"],
    ["rowUp", "moveRowUp"],
    ["rowDown", "moveRowDown"],
    ["columnBefore", "insertColBefore"],
    ["columnAfter", "insertColAfter"],
    ["deleteColumn", "deleteCol"],
    ["columnLeft", "moveColLeft"],
    ["columnRight", "moveColRight"]
  ]);
  var controls = /* @__PURE__ */ new Map([
    ["insertRowBefore", "canAddRowBefore"],
    ["insertRowAfter", "canAddRowAfter"],
    ["deleteRow", "canDeleteRow"],
    ["moveRowUp", "canMoveRowUp"],
    ["moveRowDown", "canMoveRowDown"],
    ["insertColBefore", "canAddColBefore"],
    ["insertColAfter", "canAddColAfter"],
    ["deleteCol", "canDeleteCol"],
    ["moveColLeft", "canMoveColLeft"],
    ["moveColRight", "canMoveColRight"]
  ]);
  var success = () => ({ ok: true, reason: "" });
  var failure = (reason) => ({ ok: false, reason });
  var fits = (rows, columns) => rows <= maxRows && columns <= maxColumns && rows * columns <= maxCells;
  var fitsBytes = (value) => value.length <= maxBytes && encoder.encode(value).length <= maxBytes;
  function parseTSV(text, row, column, rowCount, colCount) {
    if (!fitsBytes(text)) return null;
    const lines = text.replace(/\r\n?/g, "\n").split("\n", maxRows + 2);
    if (lines.length > 1 && lines.at(-1) === "") lines.pop();
    if (lines.length > maxRows) return null;
    const fields = lines.map((line) => line.split("	", maxColumns + 1));
    const height = Math.max(rowCount, row + fields.length);
    const width = Math.max(colCount, column + Math.max(...fields.map((line) => line.length)));
    return fits(height, width) ? { fields, height, width } : null;
  }
  function singleLineHTML(html, document2, parser, cellType, { allowLineBreak = false } = {}) {
    const template = document2.createElement("template");
    template.innerHTML = sanitizePasteHTML(html, document2);
    const fragment = template.content;
    const blocks = [...fragment.querySelectorAll("p,div")];
    const forbidden = allowLineBreak ? "table,pre,ul,ol,li,blockquote,h1,h2,h3,h4,h5,h6,hr" : "br,table,pre,ul,ol,li,blockquote,h1,h2,h3,h4,h5,h6,hr";
    if (fragment.querySelector(forbidden) || blocks.filter((node) => !node.querySelector("p,div")).length > 1) return null;
    for (const node of [...fragment.childNodes]) {
      if (node.nodeType === 3 && /[\r\n]/.test(node.data) && !node.data.trim()) node.remove();
    }
    for (const node of blocks) node.replaceWith(...node.childNodes);
    if (/[\r\n]/.test(fragment.textContent)) return null;
    for (const node of fragment.querySelectorAll("*")) {
      for (const { name } of [...node.attributes]) {
        if (!["href", "src", "title", "alt", "data-md-src"].includes(name)) node.removeAttribute(name);
      }
    }
    return parser.parse(fragment, { topNode: cellType.create(), preserveWhitespace: true }).content;
  }
  function createTableEditor({
    view,
    schema: schema2,
    blocked = () => false,
    revision = () => 0,
    applyTransaction: applyTransaction2,
    report = () => {
    },
    fail = () => {
    }
  }) {
    const { table, table_row: rowType, table_header: headerType, table_cell: cellType, paragraph, hard_break: hardBreak } = schema2.nodes;
    const parser = DOMParser.fromSchema(schema2);
    const dom = view.dom;
    const document2 = dom?.ownerDocument;
    const tables = /* @__PURE__ */ new WeakMap();
    let nextID = 0;
    let inspecting = null;
    let mouseSelection = false;
    let lastContext = null;
    function tableInfo(node) {
      let info = tables.get(node);
      if (info) return info;
      const rowCount = node.childCount;
      const colCount = node.firstChild.childCount;
      const merged = node.children.some((row) => row.children.some((cell) => cell.attrs.colspan > 1 || cell.attrs.rowspan > 1));
      const protectedTable = !node.attrs.gfm || merged || node.children.some((row) => row.childCount !== colCount || row.children.some((cell) => cell.attrs.colspan !== 1 || cell.attrs.rowspan !== 1)) || node.firstChild.children.some((cell) => cell.type !== headerType);
      info = { id: ++nextID, rowCount, colCount, merged, protected: protectedTable };
      tables.set(node, info);
      return info;
    }
    function cellAt($pos) {
      const cell = $pos.parent;
      if (cell.type !== cellType && cell.type !== headerType) return null;
      const tableDepth = $pos.depth - 2;
      return {
        node: $pos.node(tableDepth),
        pos: $pos.before(tableDepth),
        cell,
        row: $pos.index(tableDepth),
        column: $pos.index(tableDepth + 1),
        start: $pos.start()
      };
    }
    function locate() {
      const { doc: doc3, selection } = view.state;
      const from2 = cellAt(selection.$from);
      const to = cellAt(selection.$to);
      const inspected = inspecting?.doc === doc3 && inspecting.selection === selection ? inspecting.cell : null;
      let current = inspected || from2 || to;
      if (!current && !selection.empty) {
        doc3.nodesBetween(selection.from, selection.to, (node, pos) => {
          if (current) return false;
          if (node.type !== table) return void 0;
          current = { node, pos, row: 0, column: 0, cell: node.firstChild.firstChild };
          return false;
        });
      }
      if (!current) return null;
      const info = tableInfo(current.node);
      let tableDOM = typeof view.nodeDOM === "function" ? view.nodeDOM(current.pos) : null;
      if ((!tableDOM || tableDOM.tagName !== "TABLE") && typeof view.domAtPos === "function") {
        try {
          const domPos = view.domAtPos(current.pos + 1);
          const domEl = domPos?.node?.nodeType === 1 ? domPos.node : domPos?.node?.parentElement;
          tableDOM = domEl?.closest?.("table") || tableDOM;
        } catch (_) {
        }
      }
      const domProtected = !!(tableDOM?.tagName === "TABLE" && (tableDOM.getAttribute("data-md-table") !== "gfm" || tableDOM.querySelector("[colspan],[rowspan],table")));
      const isProtected = info.protected || domProtected;
      const winSel = document2?.getSelection?.();
      let domCrossCell = false;
      if (winSel && winSel.rangeCount && !winSel.isCollapsed && dom?.contains(winSel.anchorNode) && dom?.contains(winSel.focusNode)) {
        const aCell = (winSel.anchorNode?.nodeType === 1 ? winSel.anchorNode : winSel.anchorNode?.parentElement)?.closest?.("td,th");
        const fCell = (winSel.focusNode?.nodeType === 1 ? winSel.focusNode : winSel.focusNode?.parentElement)?.closest?.("td,th");
        if (aCell && fCell && aCell !== fCell) domCrossCell = true;
      }
      const sameCell = !domCrossCell && from2 && to && from2.start === to.start;
      const reason = blocked() ? "busy" : isProtected ? "html" : sameCell ? "" : "selection";
      return {
        ...current,
        ...info,
        protected: isProtected,
        from: from2,
        to,
        reason,
        token: `${info.id}:${revision()}:${current.row}:${current.column}:${current.pos}`
      };
    }
    function context() {
      if (mouseSelection) return lastContext;
      const found2 = locate();
      if (!found2) return lastContext = null;
      const { row, column, rowCount, colCount, reason, token, cell, merged } = found2;
      const enabled = !reason;
      const align = cell.attrs.align || "none";
      return lastContext = {
        inTable: true,
        row,
        column,
        rows: rowCount,
        columns: colCount,
        rowCount,
        colCount,
        reason,
        token,
        align,
        alignment: align === "none" ? "default" : align,
        gfm: found2.node.attrs.gfm,
        merged,
        protected: found2.protected,
        ...Object.fromEntries([...controls].map(([command, key]) => [key, enabled && !edgeReason(found2, command)])),
        canDeleteTable: enabled
      };
    }
    function syncToolbar() {
      if (!mouseSelection) report(context());
      return lastContext;
    }
    function setMouseSelection(active) {
      if (mouseSelection === active) return;
      if (active) context();
      mouseSelection = active;
      if (!active) syncToolbar();
    }
    function commit(tr) {
      const applied = applyTransaction2 ? applyTransaction2(tr) : view.dispatch(tr);
      if (applied === false) return failure("stale");
      view.focus?.();
      syncToolbar();
      return success();
    }
    function cellSelection(doc3, node, pos, row, column, select = false) {
      let start = pos + 3;
      for (let i = 0; i < row; i++) start += node.child(i).nodeSize;
      const targetRow = node.child(row);
      for (let i = 0; i < column; i++) start += targetRow.child(i).nodeSize;
      return TextSelection.create(doc3, start, start + (select ? targetRow.child(column).content.size : 0));
    }
    function selectCell(found2, row, column, select = true) {
      const tr = view.state.tr;
      const selection = cellSelection(tr.doc, found2.node, found2.pos, row, column, select);
      return commit(tr.setSelection(selection).scrollIntoView());
    }
    function emptyCell(row, align = null) {
      return (row === 0 ? headerType : cellType).create({ align });
    }
    function makeRow(index, width, alignment) {
      return rowType.create(null, Array.from({ length: width }, (_, column) => emptyCell(index, alignment(column))));
    }
    function insertTable(rows, cols) {
      if (blocked()) return failure("busy");
      if (locate()) return failure("format");
      if (!Number.isInteger(rows) || !Number.isInteger(cols) || rows < 1 || cols < 1 || !fits(rows, cols)) return failure("size");
      const node = table.create(null, Array.from({ length: rows }, (_, index) => makeRow(index, cols, () => null)));
      const tr = closeHistory(view.state.tr).replaceSelectionWith(node, false);
      let tablePos;
      tr.doc.descendants((child, pos) => {
        if (child !== node) return void 0;
        tablePos = pos;
        return false;
      });
      if (tablePos === void 0) return failure("format");
      const $after = tr.doc.resolve(tablePos + node.nodeSize);
      if ($after.pos === tr.doc.content.size) tr.insert($after.pos, paragraph.create());
      return commit(tr.setSelection(cellSelection(tr.doc, node, tablePos, 0, 0)).scrollIntoView());
    }
    function pasteCell(found2, payload, selectionOnly = false) {
      const html = payload.html ?? (payload.text === void 0 ? payload.value : void 0);
      const value = html ?? payload.text ?? "";
      if (typeof value !== "string") return failure("format");
      if (!fitsBytes(value)) return failure("size");
      const { selection, storedMarks } = view.state;
      const marks2 = selectionOnly ? storedMarks ?? selection.$from.marks() : void 0;
      const content = html !== void 0 ? singleLineHTML(value, document2, parser, found2.cell.type, { allowLineBreak: Boolean(payload.allowLineBreak) }) : !/[\r\n]/.test(value) && (value ? schema2.text(value, marks2) : []);
      if (!content) return failure("format");
      const tr = closeHistory(view.state.tr);
      if (selectionOnly) {
        const from2 = selection.from;
        tr.replaceWith(from2, selection.to, content);
        tr.setSelection(TextSelection.create(tr.doc, from2 + Fragment.from(content).size));
      } else {
        tr.replaceWith(found2.start, found2.start + found2.cell.content.size, content);
        tr.setSelection(TextSelection.create(tr.doc, found2.start));
      }
      return commit(tr.scrollIntoView());
    }
    function copyTSV(found2) {
      if (found2.reason && found2.reason !== "selection") return failure(found2.reason);
      const { from: from2, to, pos, rowCount, colCount } = found2;
      if (from2?.pos !== pos || to?.pos !== pos) return failure("selection");
      const single = from2.start === to.start;
      const top = single ? 0 : from2.row;
      const bottom = single ? rowCount - 1 : to.row;
      const left = single ? 0 : Math.min(from2.column, to.column);
      const right = single ? colCount - 1 : Math.max(from2.column, to.column);
      if (!fits(bottom - top + 1, right - left + 1)) return failure("size");
      let bytes = 0;
      const lines = [];
      for (let row = top; row <= bottom; row++) {
        const fields = [];
        for (let column = left; column <= right; column++) {
          const cell = found2.node.child(row).child(column);
          const text = cell.textBetween(0, cell.content.size, "", (node) => node.type === hardBreak ? " " : node.attrs.alt || "").replace(/[\t\r\n]/g, " ");
          if (text.length > maxBytes) return failure("size");
          bytes += encoder.encode(text).length + Number(row !== top || column !== left);
          if (bytes > maxBytes) return failure("size");
          fields.push(text);
        }
        lines.push(fields.join("	"));
      }
      const ending = lines.length > 1 && lines.at(-1) === "" ? "\n" : "";
      if (bytes + ending.length > maxBytes) return failure("size");
      return { ...success(), text: lines.join("\n") + ending };
    }
    function deleteTable(found2) {
      const tr = closeHistory(view.state.tr);
      const $pos = tr.doc.resolve(found2.pos);
      const end = found2.pos + found2.node.nodeSize;
      if ($pos.parent.canReplace($pos.index(), $pos.index() + 1)) tr.delete(found2.pos, end);
      else tr.replaceWith(found2.pos, end, paragraph.create());
      return commit(tr.setSelection(Selection.near(tr.doc.resolve(found2.pos))).scrollIntoView());
    }
    function execute(command, payload = {}) {
      if (typeof payload === "string") payload = { value: payload };
      payload ??= {};
      if (command === "insertTable") return insertTable(payload.rows, payload.cols ?? payload.columns);
      const found2 = locate();
      if (!found2) return failure("selection");
      if (payload.token != null && payload.token !== found2.token) return failure("stale");
      if (command === "copyTSV") return copyTSV(found2);
      if (found2.reason) return failure(found2.reason);
      if (command === "deleteTable") return deleteTable(found2);
      if (command === "pasteCell") return pasteCell(found2, payload);
      let align = payload.align === void 0 ? payload.value : payload.align;
      if (["alignDefault", "alignLeft", "alignCenter", "alignRight"].includes(command)) {
        align = command.slice(5).toLowerCase();
        command = "align";
      }
      if (command === "align") {
        if (align === void 0 || align === "cycle") {
          const currentAlign = found2.cell.attrs.align || "none";
          align = alignments[(alignments.indexOf(currentAlign) + 1) % alignments.length];
        }
        if (align === "default" || align === null) align = "none";
        if (!alignments.includes(align)) return failure("command");
      }
      return editTable(found2, hostCommands.get(command) || command, payload, align);
    }
    function editTable(found2, command, payload, align, tabAppend = false) {
      const { node, pos, row, column, rowCount, colCount } = found2;
      const reason = edgeReason(found2, command);
      if (reason) return failure(reason);
      const rows = [...node.children];
      const alignment = (index) => rows[0].child(index).attrs.align;
      let targetRow = row;
      let targetColumn = column;
      switch (command) {
        case "insertRowBefore":
        case "insertRowAfter":
          targetRow = row + Number(command === "insertRowAfter");
          rows.splice(targetRow, 0, makeRow(targetRow, colCount, alignment));
          if (tabAppend) targetColumn = 0;
          break;
        case "deleteRow":
          rows.splice(row, 1);
          targetRow = Math.min(row, rows.length - 1);
          break;
        case "moveRowUp":
        case "moveRowDown":
          targetRow = row + (command === "moveRowUp" ? -1 : 1);
          [rows[row], rows[targetRow]] = [rows[targetRow], rows[row]];
          break;
        case "insertColBefore":
        case "insertColAfter": {
          targetColumn = column + Number(command === "insertColAfter");
          const align2 = alignment(column);
          changeColumns(rows, (cells, index) => cells.splice(targetColumn, 0, emptyCell(index, align2)));
          break;
        }
        case "deleteCol":
          changeColumns(rows, (cells) => cells.splice(column, 1));
          targetColumn = Math.min(column, colCount - 2);
          break;
        case "moveColLeft":
        case "moveColRight":
          targetColumn = column + (command === "moveColLeft" ? -1 : 1);
          changeColumns(rows, (cells) => {
            [cells[column], cells[targetColumn]] = [cells[targetColumn], cells[column]];
          });
          break;
        case "align":
          changeColumns(rows, (cells) => {
            const cell = cells[column];
            cells[column] = cell.type.create({ ...cell.attrs, align: align === "none" ? null : align }, cell.content, cell.marks);
          });
          break;
        case "pasteTSV": {
          const text = payload.text ?? payload.value ?? "";
          if (typeof text !== "string") return failure("format");
          const parsed = parseTSV(text, row, column, rowCount, colCount);
          if (!parsed) return failure("size");
          const { fields, height, width } = parsed;
          for (let index = 0; index < height; index++) {
            if (index >= rows.length) rows.push(makeRow(index, width, alignment));
            const values = fields[index - row];
            if (!values && rows[index].childCount === width) continue;
            const cells = [...rows[index].children];
            while (cells.length < width) cells.push(emptyCell(index));
            values?.forEach((value, offset) => {
              const cell = cells[column + offset];
              cells[column + offset] = cell.type.create(cell.attrs, value ? schema2.text(value) : null, cell.marks);
            });
            rows[index] = rows[index].type.create(rows[index].attrs, cells, rows[index].marks);
          }
          targetRow = row + fields.length - 1;
          targetColumn = column + fields.at(-1).length - 1;
          break;
        }
        default:
          return failure("command");
      }
      const replacement = node.type.create(node.attrs, rows, node.marks);
      const tr = closeHistory(view.state.tr);
      if (!node.eq(replacement)) tr.replaceWith(pos, pos + node.nodeSize, replacement);
      return commit(tr.setSelection(cellSelection(tr.doc, replacement, pos, targetRow, targetColumn)).scrollIntoView());
    }
    function leaveTable(found2, direction) {
      const tr = view.state.tr;
      const boundary = found2.pos + (direction > 0 ? found2.node.nodeSize : 0);
      const $boundary = tr.doc.resolve(boundary);
      const selection = GapCursor.valid($boundary) ? new GapCursor($boundary) : Selection.findFrom($boundary, direction, true);
      if (!selection || cellAt(selection.$from)?.pos === found2.pos) return false;
      return commit(tr.setSelection(selection).scrollIntoView()).ok;
    }
    function navigate(backwards) {
      const found2 = locate();
      if (!found2 || found2.reason) return false;
      const { row, column, rowCount, colCount } = found2;
      const index = row * colCount + column + (backwards ? -1 : 1);
      if (index < 0) return leaveTable(found2, -1);
      if (index >= rowCount * colCount) {
        const result = editTable(found2, "insertRowAfter", {}, void 0, true);
        if (!result.ok) fail(result.reason);
        return true;
      }
      return selectCell(found2, Math.floor(index / colCount), index % colCount).ok;
    }
    function rejectOversizedTabAtDOM(event) {
      if (event.key !== "Tab" || event.shiftKey || event.altKey || event.metaKey || event.ctrlKey || event.isComposing || blocked()) return false;
      const anchor = document2?.getSelection?.()?.anchorNode;
      const cell = (anchor?.nodeType === 1 ? anchor : anchor?.parentElement)?.closest?.("td,th");
      const row = cell?.closest("tr");
      const tableDOM = row?.closest("table");
      if (!tableDOM || !dom?.contains(tableDOM) || tableDOM.getAttribute("data-md-table") !== "gfm" || tableDOM.querySelector("[colspan],[rowspan],table")) return false;
      if (row.rowIndex !== tableDOM.rows.length - 1 || cell.cellIndex !== row.cells.length - 1 || fits(tableDOM.rows.length + 1, row.cells.length)) return false;
      fail("size");
      return true;
    }
    function handleKeyDown2(viewOrEvent, maybeEvent) {
      const event = maybeEvent ?? viewOrEvent;
      if (!["Shift", "Alt", "Control", "Meta"].includes(event.key)) setMouseSelection(false);
      if (inspecting) {
        inspecting = null;
        syncToolbar();
      }
      if (event.isComposing || event.ctrlKey || event.metaKey) return false;
      if (event.key === "Tab") {
        if (event.altKey) return false;
        return navigate(event.shiftKey);
      }
      if (event.key !== "Enter" && event.key !== "Escape") return false;
      const found2 = locate();
      if (!found2 || found2.reason === "busy") return false;
      if (event.key === "Escape") return leaveTable(found2, 1);
      const result = found2.reason ? failure(found2.reason) : commit(view.state.tr.replaceSelectionWith(hardBreak.create(), false).scrollIntoView());
      if (!result.ok) fail(result.reason);
      return true;
    }
    function handlePaste(viewOrEvent, maybeEvent) {
      const event = maybeEvent ?? viewOrEvent;
      const clipboard = event.clipboardData;
      const found2 = locate();
      if (!clipboard || !found2) return false;
      const text = clipboard.getData("text/plain");
      const html = clipboard.getData("text/html");
      let result;
      if (found2.reason) {
        result = failure(found2.reason);
      } else if (text.includes("	") || /[\r\n]/.test(text) && (!html || /<table(?=[\s>])/i.test(html))) {
        result = execute("pasteTSV", { text });
      } else {
        if (clipboard.getData("application/x-fastra-markdown") || clipboard.files?.length) return false;
        if (!text && !html) return false;
        if (!fitsBytes(text)) result = failure("size");
        else {
          const selection = view.state.selection;
          const fullCell = !selection.empty && selection.from === found2.start && selection.to === found2.start + found2.cell.content.size;
          result = pasteCell(found2, html ? { html, allowLineBreak: true } : { text }, !fullCell);
        }
      }
      event.preventDefault?.();
      if (!result.ok) fail(result.reason);
      return true;
    }
    function pasteText(text) {
      const found2 = locate();
      if (!found2) return null;
      const result = found2.reason ? failure(found2.reason) : /[\t\r\n]/.test(text) ? execute("pasteTSV", { text }) : pasteCell(found2, { text }, true);
      if (!result.ok) fail(result.reason);
      return result.ok;
    }
    function handleCopy(viewOrEvent, maybeEvent) {
      const event = maybeEvent ?? viewOrEvent;
      const found2 = locate();
      if (!event.clipboardData || !found2?.from || !found2.to || found2.from.start === found2.to.start || found2.protected) return false;
      const result = copyTSV(found2);
      if (!result.ok && result.reason !== "size") return false;
      event.preventDefault();
      if (result.ok) event.clipboardData.setData("text/plain", result.text);
      else fail(result.reason);
      return true;
    }
    function handleClick2(viewOrEvent, position, maybeEvent) {
      const event = maybeEvent ?? viewOrEvent;
      const { doc: doc3, selection } = view.state;
      if (typeof position !== "number") {
        const cell2 = event.target?.closest?.("td,th");
        if (cell2 && dom?.contains(cell2)) position = view.posAtDOM(cell2, 0);
      }
      const cell = typeof position === "number" && position >= 0 && position <= doc3.content.size ? cellAt(doc3.resolve(position)) : null;
      inspecting = cell && tableInfo(cell.node).protected ? { doc: doc3, selection, cell } : null;
      syncToolbar();
      return false;
    }
    const startMouseSelection = (event) => {
      if (event.button === 0) setMouseSelection(true);
    };
    const finishMouseSelection = () => setMouseSelection(false);
    dom?.addEventListener("mousedown", startMouseSelection, true);
    document2?.addEventListener("mouseup", finishMouseSelection, true);
    document2?.defaultView?.addEventListener("blur", finishMouseSelection);
    return {
      context,
      execute,
      insertTable,
      handleKeyDown: handleKeyDown2,
      rejectOversizedTabAtDOM,
      handlePaste,
      handleCopy,
      handleClick: handleClick2,
      navigate,
      pasteText,
      syncToolbar,
      command: (name, value, token) => execute(name, { value, token }),
      get selectingWithMouse() {
        return mouseSelection;
      },
      set selectingWithMouse(active) {
        setMouseSelection(Boolean(active));
      },
      destroy() {
        dom?.removeEventListener("mousedown", startMouseSelection, true);
        document2?.removeEventListener("mouseup", finishMouseSelection, true);
        document2?.defaultView?.removeEventListener("blur", finishMouseSelection);
        inspecting = null;
        mouseSelection = false;
        lastContext = null;
      }
    };
  }
  function changeColumns(rows, edit) {
    rows.forEach((row, index) => {
      const cells = [...row.children];
      edit(cells, index);
      rows[index] = row.type.create(row.attrs, cells, row.marks);
    });
  }
  function edgeReason({ row, column, rowCount, colCount }, command) {
    if (["insertRowBefore", "insertRowAfter"].includes(command) && !fits(rowCount + 1, colCount) || ["insertColBefore", "insertColAfter"].includes(command) && !fits(rowCount, colCount + 1)) return "size";
    switch (command) {
      case "insertRowBefore":
      case "deleteRow":
        return row === 0 ? "edge" : "";
      case "moveRowUp":
        return row <= 1 ? "edge" : "";
      case "moveRowDown":
        return row === 0 || row === rowCount - 1 ? "edge" : "";
      case "deleteCol":
        return colCount === 1 ? "edge" : "";
      case "moveColLeft":
        return column === 0 ? "edge" : "";
      case "moveColRight":
        return column === colCount - 1 ? "edge" : "";
      default:
        return "";
    }
  }

  // src/bridge.js
  var MAX_SOURCE_CONTEXT_BYTES = 33554432;
  function postVisualMessage(payload) {
    try {
      window.webkit?.messageHandlers?.visualMarkdown?.postMessage(payload);
    } catch (_) {
    }
  }
  function postCopyMessage(payload) {
    try {
      window.webkit?.messageHandlers?.markdownCopy?.postMessage(payload);
    } catch (_) {
    }
  }
  function collectImageTransactions(doc3) {
    const seen = /* @__PURE__ */ new Set();
    doc3.descendants((node) => {
      if (node.type.name === "image" && node.attrs.imageTransaction) {
        seen.add(node.attrs.imageTransaction);
      }
      return true;
    });
    return Array.from(seen);
  }
  function collectOrderedImageTransactions(doc3) {
    return collectImageTransactions(doc3).slice().sort();
  }
  function installFastraVisualBridge() {
    let view = null;
    let root = null;
    let session = "";
    let base2 = "";
    let revision = 0;
    let docMutationVersion = 0;
    let publishedMutationVersion = 0;
    let composing = false;
    let notifyCompositionEnd = false;
    let fenced = false;
    let failed = false;
    let initializing = false;
    let actionFenced = false;
    let lastEditableProp = null;
    let domObserverPausedForOversizedTable = false;
    let flushingDom = false;
    let clipboardBookmark = null;
    let imageFenceRevision = null;
    let lastImageTransactions = "[]";
    let lastInputType = "";
    let emittedInputType = "";
    let pendingInputType = "";
    let emittedEditorState = null;
    let clipboardLimit = 0;
    let copiedHTML = null;
    let lastTableContext = null;
    let lastReportedTableKey = null;
    let selectingWithMouse = false;
    let mouseDragAnchor = null;
    let mouseDragStart = null;
    let mouseDragMoved = false;
    let mouseDragHadButtons = false;
    let sourceReplacementEnabled = false;
    let sourceContextBytes = 0;
    let bookmarkID = 0;
    let clipboardSelectionGeneration = 0;
    let observedClipboardSel = null;
    let viewportRestoring = false;
    let viewportGeneration = 0;
    let viewportPending = false;
    let listenersInstalledOnRoot = /* @__PURE__ */ new WeakSet();
    let globalListenersInstalled = false;
    let tables = null;
    let lastPreOpSnapshot = null;
    const nativeActionIDs = /* @__PURE__ */ new Set();
    const bookmarks = /* @__PURE__ */ new Map();
    const opaqueSources = /* @__PURE__ */ Object.create(null);
    const imageUrlOverrides = /* @__PURE__ */ new Map();
    const unresolvedImageSources = /* @__PURE__ */ new Set();
    let trackUnresolvedImages = false;
    const originals = /* @__PURE__ */ new Map();
    const contexts = /* @__PURE__ */ new Map();
    function postMessage(payload) {
      postVisualMessage(payload);
    }
    function viewportPosition() {
      return { x: Math.max(0, window.scrollX || 0), y: Math.max(0, window.scrollY || 0) };
    }
    function reportViewport() {
      if (!viewportRestoring && session) {
        postMessage({ kind: "viewport", session, revision, viewport: viewportPosition() });
      }
    }
    async function restoreViewport(value) {
      if (!value || ![value.x, value.y].every((n) => Number.isFinite(n) && n >= 0 && n <= 1e8)) return;
      const req = ++viewportGeneration;
      viewportRestoring = true;
      let settled = 0;
      for (let attempt = 0; attempt < 60 && req === viewportGeneration; attempt++) {
        window.scrollTo?.(value.x, value.y);
        const actual = viewportPosition();
        if (Math.abs(actual.x - value.x) < 1 && Math.abs(actual.y - value.y) < 1) {
          if (++settled === 2) break;
        } else {
          settled = 0;
        }
        await new Promise((resolve) => setTimeout(resolve, 16));
      }
      if (req === viewportGeneration) {
        viewportRestoring = false;
        reportViewport();
      }
    }
    function serialize() {
      if (!view) return base2;
      return serializeDocument(view.state.doc, {
        contexts,
        originals,
        opaqueSources,
        lastInputType
      });
    }
    const diagnostics = createDiagnosticsController({
      postMessage,
      getSession: () => session,
      getRevision: () => revision,
      getRoot: () => root,
      isFenced: () => fenced,
      isComposing: () => composing,
      getLastInputType: () => lastInputType,
      serializeMarkdown: serialize
    });
    function updateFence() {
      fenced = failed || initializing || actionFenced || nativeActionIDs.size > 0 || clipboardBookmark !== null || imageFenceRevision !== null;
      const nextEditable = !fenced && !failed;
      if (view && lastEditableProp !== nextEditable) {
        if (nextEditable && !(view.state.selection instanceof NodeSelection)) syncDOMSelectionToProseMirror();
        lastEditableProp = nextEditable;
        view.setProps({ editable: () => !fenced && !failed });
      }
      if (root) {
        const desired = fenced || failed ? "false" : "true";
        if (root.contentEditable !== desired) {
          root.contentEditable = desired;
        }
      }
    }
    function notifyHistoryAndOutline() {
      if (!view || !session) return;
      const hist = getHistoryState(view.state);
      postMessage({
        kind: "historyState",
        session,
        revision,
        historyState: hist,
        ...hist
      });
      postMessage({
        kind: "outlinePosition",
        session,
        revision,
        index: outlinePosition()
      });
      reportTableContext();
    }
    let pendingEmitTimer = null;
    function clearPendingEmitTimer() {
      if (pendingEmitTimer !== null) {
        clearTimeout(pendingEmitTimer);
        pendingEmitTimer = null;
      }
    }
    function flushDOMObserver() {
      try {
        view?.domObserver?.flush?.();
      } catch (_) {
      }
    }
    function resumeDomObserverIfPaused() {
      if (!domObserverPausedForOversizedTable) return;
      try {
        view?.domObserver?.start?.();
      } catch (_) {
      }
      domObserverPausedForOversizedTable = false;
    }
    function captureDOMSelectionSnapshot() {
      if (!root) return null;
      const winSel = document.getSelection?.();
      if (!winSel || !winSel.rangeCount) return null;
      const range = winSel.getRangeAt(0);
      if (!root.contains(range.commonAncestorContainer)) return null;
      return {
        startContainer: range.startContainer,
        startOffset: range.startOffset,
        endContainer: range.endContainer,
        endOffset: range.endOffset,
        collapsed: range.collapsed,
        anchorNode: winSel.anchorNode || range.startContainer,
        anchorOffset: winSel.anchorNode ? winSel.anchorOffset : range.startOffset,
        focusNode: winSel.focusNode || range.endContainer,
        focusOffset: winSel.focusNode ? winSel.focusOffset : range.endOffset
      };
    }
    function syncDOMSelectionToProseMirror(snapshot = null) {
      if (!view || !root) return false;
      const active = snapshot && root.contains(snapshot.startContainer) && root.contains(snapshot.endContainer) ? snapshot : captureDOMSelectionSnapshot();
      if (!active) return false;
      if ((view.state.selection instanceof NodeSelection || view.state.selection instanceof GapCursor) && active.collapsed) return false;
      try {
        const doc3 = view.state.doc;
        if (active.startContainer === root && active.startOffset === 0 && active.endContainer === root && active.endOffset === root.childNodes.length && !active.collapsed) {
          const allSel = new AllSelection(doc3);
          if (!(view.state.selection instanceof AllSelection)) {
            view.dispatch(view.state.tr.setSelection(allSel).setMeta("addToHistory", false).setMeta("fastraAllowFenced", true));
            return true;
          }
          return false;
        }
        if (active.startContainer === active.endContainer && active.endOffset === active.startOffset + 1 && active.startContainer.nodeType === 1) {
          const selectedNode = active.startContainer.childNodes[active.startOffset];
          if (selectedNode?.nodeType === 1 && (selectedNode.tagName === "IMG" || selectedNode.hasAttribute?.("data-tex") || selectedNode.hasAttribute?.("data-md-opaque"))) {
            const candidates = [];
            try {
              candidates.push(view.posAtDOM(active.startContainer, active.startOffset));
            } catch (_) {
            }
            try {
              const domPos = view.posAtDOM(selectedNode, 0);
              candidates.push(domPos - 1, domPos);
            } catch (_) {
            }
            for (const rawPos of candidates) {
              const pos = Math.max(0, Math.min(rawPos, doc3.content.size));
              const atNode = doc3.nodeAt(pos);
              if (atNode && (atNode.type.name === "image" || atNode.type.name === "math_inline" || atNode.type.name === "opaque_inline" || atNode.type.name === "math_block" || atNode.type.name === "opaque_block")) {
                const nodeSel = NodeSelection.create(doc3, pos);
                if (!(view.state.selection instanceof NodeSelection) || view.state.selection.from !== nodeSel.from) {
                  view.dispatch(view.state.tr.setSelection(nodeSel).setMeta("addToHistory", false).setMeta("fastraAllowFenced", true));
                  return true;
                }
                return false;
              }
            }
          }
        }
        const anchorPos = Math.max(0, Math.min(view.posAtDOM(active.anchorNode, active.anchorOffset), doc3.content.size));
        const focusPos = Math.max(0, Math.min(view.posAtDOM(active.focusNode, active.focusOffset), doc3.content.size));
        let nextSel;
        if (active.collapsed && active.startContainer.nodeType === 1) {
          const el = active.startContainer;
          const offset = active.startOffset;
          if (offset === el.childNodes.length && offset > 0) {
            if (el === root) {
              nextSel = Selection.near(doc3.resolve(doc3.content.size), -1);
            } else {
              let targetNode = el;
              while (targetNode.nodeType === 1) {
                let child = targetNode.lastChild;
                while (child && child.nodeType === 1 && (child.classList?.contains("ProseMirror-trailingBreak") || child.classList?.contains("ProseMirror-separator"))) {
                  child = child.previousSibling;
                }
                if (!child) break;
                targetNode = child;
              }
              let innerPos;
              if (targetNode.nodeType === 3) {
                innerPos = view.posAtDOM(targetNode, targetNode.data.length);
              } else if (/^(BR|IMG|HR|INPUT|WBR)$/.test(targetNode.tagName) || targetNode.hasAttribute?.("data-tex") || targetNode.hasAttribute?.("data-md-opaque")) {
                const parent = targetNode.parentNode;
                const childIdx = parent ? Array.prototype.indexOf.call(parent.childNodes, targetNode) : -1;
                innerPos = parent && childIdx >= 0 ? view.posAtDOM(parent, childIdx + 1) : view.posAtDOM(el, offset);
              } else {
                innerPos = view.posAtDOM(targetNode, targetNode.childNodes?.length || 0);
              }
              nextSel = Selection.near(doc3.resolve(Math.max(0, Math.min(innerPos, doc3.content.size))), -1);
            }
          } else if (offset === 0) {
            nextSel = Selection.near(doc3.resolve(anchorPos), 1);
          } else {
            nextSel = TextSelection.between(doc3.resolve(anchorPos), doc3.resolve(focusPos));
          }
        } else {
          nextSel = TextSelection.between(doc3.resolve(anchorPos), doc3.resolve(focusPos));
        }
        if (view.state.selection.anchor !== nextSel.anchor || view.state.selection.head !== nextSel.head || view.state.selection instanceof NodeSelection || view.state.selection instanceof AllSelection) {
          view.dispatch(view.state.tr.setSelection(nextSel).setMeta("addToHistory", false).setMeta("fastraAllowFenced", true));
          return true;
        }
      } catch (_) {
      }
      return false;
    }
    function syncProseMirrorSelectionToDOM({ force = false } = {}) {
      if (!view || !root || !force && view.hasFocus?.()) return;
      try {
        const sel = view.state.selection;
        const winSel = document.getSelection?.();
        if (!winSel) return;
        const anchorDOM = view.domAtPos(sel.anchor);
        const headDOM = sel.empty ? anchorDOM : view.domAtPos(sel.head);
        if (anchorDOM?.node && headDOM?.node) {
          if (winSel.rangeCount && winSel.anchorNode === anchorDOM.node && winSel.anchorOffset === anchorDOM.offset && winSel.focusNode === headDOM.node && winSel.focusOffset === headDOM.offset) {
            return;
          }
          if (sel.anchor <= sel.head && winSel.removeAllRanges && winSel.addRange) {
            const range = document.createRange();
            range.setStart(anchorDOM.node, anchorDOM.offset);
            range.setEnd(headDOM.node, headDOM.offset);
            winSel.removeAllRanges();
            winSel.addRange(range);
          } else {
            winSel.setBaseAndExtent?.(anchorDOM.node, anchorDOM.offset, headDOM.node, headDOM.offset);
          }
        }
      } catch (_) {
      }
    }
    function syncFromDOM() {
      const snap = captureDOMSelectionSnapshot();
      flushDOMObserver();
      return syncDOMSelectionToProseMirror(snap);
    }
    function observeClipboardSelection() {
      if (!view) return null;
      const { from: from2, to, anchor, head } = view.state.selection;
      const current = { from: from2, to, anchor, head };
      if (!observedClipboardSel || observedClipboardSel.from !== current.from || observedClipboardSel.to !== current.to || observedClipboardSel.anchor !== current.anchor || observedClipboardSel.head !== current.head) {
        clipboardSelectionGeneration++;
        observedClipboardSel = current;
      }
      return current;
    }
    function currentClipboardSelection(saved) {
      if (saved.clipboardSelectionGeneration === void 0) return true;
      const current = observeClipboardSelection();
      return !!current && saved.clipboardSelectionGeneration === clipboardSelectionGeneration && saved.clipboardSelection?.from === current.from && saved.clipboardSelection?.to === current.to;
    }
    function toolbarTableContext() {
      if (!selectingWithMouse) {
        lastTableContext = tables?.context?.() || null;
      }
      return lastTableContext;
    }
    function reportTableContext() {
      if (selectingWithMouse || domObserverPausedForOversizedTable || !session) return;
      const context = toolbarTableContext();
      const key = JSON.stringify({ session, revision, context });
      if (key === lastReportedTableKey) return;
      lastReportedTableKey = key;
      postMessage({
        kind: "tableContext",
        session,
        revision,
        context
      });
    }
    function outlineHeadings() {
      if (!root) return [];
      return Array.from(root.querySelectorAll("h1,h2,h3,h4,h5,h6")).filter(
        (n) => !n.closest("[data-md-opaque],[data-tex]") && !n.hasAttribute("data-md-outline-ignore")
      );
    }
    function outlinePosition() {
      if (!view || !root) return -1;
      const headings = outlineHeadings();
      if (!headings.length) return -1;
      let anchorDOM = null;
      try {
        const domPos = view.domAtPos(view.state.selection.anchor);
        anchorDOM = domPos.node?.nodeType === 1 ? domPos.node : domPos.node?.parentElement;
      } catch (_) {
        return -1;
      }
      if (!anchorDOM || !root.contains(anchorDOM)) return -1;
      let index = -1;
      headings.forEach((heading, i) => {
        if (heading.contains(anchorDOM) || heading === anchorDOM || heading.compareDocumentPosition(anchorDOM) & 4) {
          index = i;
        }
      });
      return index;
    }
    function buildContextEntry(cfg, prefix, parsedGroups, targetOriginals, targetContexts, targetOpaque) {
      const context = {
        blocks: (cfg.blocks || []).map((b) => ({ ...b, id: prefix + String(b.id) })),
        hiddenPrefixes: /* @__PURE__ */ new Map(),
        trailingHidden: /* @__PURE__ */ new Set(),
        trailingOwner: null
      };
      let preceding = [];
      for (const block of context.blocks) {
        if (block.hidden) {
          preceding.push(block);
          continue;
        }
        context.hiddenPrefixes.set(block.id, preceding);
        preceding = [];
        context.trailingOwner = block.id;
        const originalID = block.id.slice(prefix.length);
        const parsed = parsedGroups.get(originalID);
        if (parsed) {
          targetOriginals.set(block.id, {
            source: block.source,
            canonicalSnapshot: parsed.canonicalSnapshot,
            structure: parsed.structure,
            context,
            ignoredHeadings: parsed.ignoredHeadings
          });
        }
      }
      context.trailingHidden = new Set(preceding.map((b) => b.id));
      Object.assign(targetOpaque, cfg.opaqueSources || {});
      targetContexts.set(prefix, context);
      return context;
    }
    function emitChangeIfNeeded(forceImageTransactions = null) {
      clearPendingEmitTimer();
      if (!view || initializing || failed || composing) return;
      const previousBase = base2;
      const current = serialize();
      const currentImageTx = forceImageTransactions || collectOrderedImageTransactions(view.state.doc);
      const currentImageState = JSON.stringify(currentImageTx);
      if (currentImageState === lastImageTransactions && imageFenceRevision === null) lastPreOpSnapshot = null;
      if (current === previousBase && currentImageState === lastImageTransactions) {
        publishedMutationVersion = docMutationVersion;
        notifyHistoryAndOutline();
        return;
      }
      const imageChanged = currentImageState !== lastImageTransactions;
      if (imageChanged) {
        imageFenceRevision = revision + 1;
        updateFence();
      }
      revision += 1;
      publishedMutationVersion = docMutationVersion;
      base2 = current;
      lastImageTransactions = currentImageState;
      emittedEditorState = view.state;
      const hist = getHistoryState(view.state);
      emittedInputType = lastInputType;
      postMessage({
        kind: "change",
        session,
        base: previousBase,
        markdown: current,
        revision,
        imageTransactions: currentImageTx,
        inputType: emittedInputType,
        viewport: viewportPosition(),
        historyState: hist,
        ...hist
      });
      lastInputType = "";
      lastReportedTableKey = null;
      notifyHistoryAndOutline();
    }
    function scheduleEmitChange() {
      clearPendingEmitTimer();
      pendingInputType = lastInputType;
      pendingEmitTimer = setTimeout(() => {
        pendingEmitTimer = null;
        emitChangeIfNeeded();
      }, 80);
    }
    function createBridgePlugin() {
      return new Plugin({
        appendTransaction(transactions, oldState, newState) {
          if (!transactions.some((tr) => tr.docChanged)) return null;
          let fixTr = null;
          newState.doc.descendants((node, pos) => {
            rememberUnresolvedImage(node);
            if (node.type === schema.nodes.blank_line && node.content.size > 0) {
              if (!fixTr) fixTr = newState.tr;
              fixTr.setNodeMarkup(pos, schema.nodes.paragraph, {
                mdContext: node.attrs.mdContext || "",
                mdBlockId: node.attrs.mdBlockId || null,
                mdBlockSub: node.attrs.mdBlockSub || 0,
                mdBlockTotal: node.attrs.mdBlockTotal || 1,
                mdEmpty: false
              }, node.marks);
              return false;
            }
            if (node.type === schema.nodes.paragraph && node.attrs.mdEmpty && node.content.size > 0) {
              if (!fixTr) fixTr = newState.tr;
              fixTr.setNodeMarkup(pos, null, { ...node.attrs, mdEmpty: false }, node.marks);
            }
            return true;
          });
          const oldImages = JSON.stringify(collectOrderedImageTransactions(oldState.doc));
          const newImages = JSON.stringify(collectOrderedImageTransactions(newState.doc));
          if (oldImages !== newImages) {
            fixTr = closeHistory(fixTr || newState.tr);
          }
          return fixTr;
        }
      });
    }
    function rememberUnresolvedImage(node) {
      if (trackUnresolvedImages && node.type === schema.nodes.image && !node.attrs.src && node.attrs.mdSrc) {
        unresolvedImageSources.add(node.attrs.mdSrc);
      }
    }
    function applyTransaction2(tr, { allowFenced = false, inputType = "" } = {}) {
      if (!view) return false;
      if (fenced && !allowFenced && tr.docChanged) return false;
      if (inputType) lastInputType = inputType;
      if (allowFenced) tr.setMeta("fastraAllowFenced", true);
      tr.setMeta("fastraImmediate", true);
      view.dispatch(tr);
      return true;
    }
    function toggleTaskAtPos(pos, checked) {
      if (!view || fenced) return;
      const node = view.state.doc.nodeAt(pos);
      if (!node || node.type !== schema.nodes.list_item || node.attrs.task === null) return;
      const tr = closeHistory(view.state.tr.setNodeMarkup(pos, null, { ...node.attrs, task: checked }));
      applyTransaction2(tr, { inputType: "taskToggle" });
    }
    function extractUriToken(src) {
      if (!src) return "";
      const withoutQuery = String(src).split(/[?#]/)[0];
      return withoutQuery.split("/").pop() || "";
    }
    function applyDomImageOverridesOnImages(doc3) {
      if (!view) return;
      const tr = view.state.tr.setMeta("addToHistory", false).setMeta("fastraAllowFenced", true);
      doc3.descendants((node, pos) => {
        if (node.type === schema.nodes.image) {
          const mapped = imageUrlOverrides.get(node.attrs.src || node.attrs.mdSrc);
          if (mapped && mapped !== node.attrs.src) {
            tr.setNodeMarkup(pos, null, { ...node.attrs, src: mapped });
          }
        }
        return true;
      });
      if (tr.docChanged) view.dispatch(tr);
    }
    function imageNodePosition(target) {
      const img = target?.closest?.("img");
      if (!img || img.closest("[data-md-opaque],[data-tex]")) return null;
      try {
        const pos = view.posAtDOM(img, 0);
        if (view.state.doc.nodeAt(pos)?.type === schema.nodes.image && view.nodeDOM(pos) === img) return pos;
      } catch (_) {
      }
      return null;
    }
    function createEditorView(doc3, rawContainer) {
      domObserverPausedForOversizedTable = false;
      lastEditableProp = null;
      lastReportedTableKey = null;
      mouseDragAnchor = null;
      mouseDragStart = null;
      mouseDragMoved = false;
      if (view) {
        tables?.destroy?.();
        view.destroy();
        view = null;
      }
      while (rawContainer.firstChild) rawContainer.firstChild.remove();
      let tableEditorInstance = null;
      const km = buildKeymap({
        schema,
        getTableEditor: () => tableEditorInstance,
        isBlocked: () => fenced || composing,
        onUndo: () => runHistory("undo"),
        onRedo: () => runHistory("redo")
      });
      const state = EditorState.create({
        schema,
        doc: doc3,
        plugins: [
          history(),
          buildInputRules(schema),
          km,
          gapCursor(),
          createBridgePlugin()
        ]
      });
      view = new EditorView({ mount: rawContainer }, {
        state,
        editable: () => !fenced && !failed,
        nodeViews: createNodeViews({
          getImageOverrides: () => imageUrlOverrides,
          isBlocked: () => fenced || composing || failed,
          onToggleTask: toggleTaskAtPos
        }),
        handleKeyDown(v, event) {
          if (event.isComposing) return false;
          syncDOMSelectionToProseMirror();
          if (tableEditorInstance?.handleKeyDown?.(v, event)) return true;
          return false;
        },
        handleClick(v, pos, event) {
          tableEditorInstance?.handleClick?.(v, pos, event);
          return false;
        },
        handleDOMEvents: {
          keydown(_view, event) {
            if (event.isComposing) return true;
            return false;
          },
          beforeinput(_view, event) {
            if (fenced || failed) {
              event.preventDefault();
              return true;
            }
            resumeDomObserverIfPaused();
            lastInputType = event.inputType || "";
            if (event.inputType === "historyUndo") {
              event.preventDefault();
              runHistory("undo");
              return true;
            }
            if (event.inputType === "historyRedo") {
              event.preventDefault();
              runHistory("redo");
              return true;
            }
            return false;
          },
          compositionstart() {
            composing = true;
            return false;
          },
          compositionend() {
            composing = false;
            emitChangeIfNeeded();
            if (notifyCompositionEnd) {
              notifyCompositionEnd = false;
              postMessage({ kind: "retryExternalCheck", session });
            }
            return false;
          },
          paste(_view, event) {
            if (fenced || failed) {
              event.preventDefault();
              return true;
            }
            resumeDomObserverIfPaused();
            syncDOMSelectionToProseMirror();
            const plain = event.clipboardData?.getData("text/plain") || "";
            const html = event.clipboardData?.getData("text/html") || "";
            if (tableEditorInstance?.handlePaste?.(_view, event)) {
              return true;
            }
            if (event.clipboardData?.getData("application/x-fastra-markdown")) {
              event.preventDefault();
              postMessage({ kind: "pasteMarkdown", session, bookmark: window.fastraVisual.bookmark() });
              return true;
            }
            if (event.clipboardData?.files?.length) {
              event.preventDefault();
              postMessage({ kind: "pasteImage", session, bookmark: window.fastraVisual.bookmark() });
              return true;
            }
            if (html) {
              event.preventDefault();
              if (isCodeSelection(view.state.selection)) {
                insertPlainText(view.state.selection, plain || clipboardPlainText(html));
                return true;
              }
              const cleaned = sanitizePasteHTML(html, root.ownerDocument);
              const slice2 = buildPasteSlice(cleaned);
              if (slice2) {
                applyTransaction2(closeHistory(view.state.tr).replaceSelection(slice2).scrollIntoView(), { inputType: "insertFromPaste" });
              }
              return true;
            }
            if (plain) {
              event.preventDefault();
              insertPlainText(view.state.selection, plain);
              return true;
            }
            return false;
          },
          drop(_view, event) {
            event.preventDefault();
            const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
            if (coords) {
              applyTransaction2(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(coords.pos))), { allowFenced: true });
            }
            return true;
          },
          dragover(_view, event) {
            event.preventDefault();
            return false;
          },
          contextmenu(_view, event) {
            const pos = imageNodePosition(event.target);
            if (pos === null || fenced) return false;
            event.preventDefault();
            applyTransaction2(view.state.tr.setSelection(NodeSelection.create(view.state.doc, pos)));
            postMessage({ kind: "imageMenu", session, x: event.clientX, y: event.clientY });
            return true;
          },
          click(_view, event) {
            if (fenced) {
              event.preventDefault();
              return true;
            }
            const pos = imageNodePosition(event.target);
            if (pos !== null) {
              event.preventDefault();
              applyTransaction2(view.state.tr.setSelection(NodeSelection.create(view.state.doc, pos)));
              return true;
            }
            if (event.target?.closest?.("a")) {
              event.preventDefault();
              return true;
            }
            return false;
          },
          copy(_view, event) {
            if (tableEditorInstance?.handleCopy?.(_view, event)) return true;
            return handleCopyOrCut(event, false);
          },
          cut(_view, event) {
            return handleCopyOrCut(event, true);
          }
        },
        dispatchTransaction(tr) {
          const allowFenced = tr.getMeta("fastraAllowFenced") === true || flushingDom;
          if (tr.docChanged && (fenced || failed) && !allowFenced) {
            return;
          }
          const prevState = view.state;
          let candidateState = prevState.apply(tr);
          const imageChanged = tr.docChanged && JSON.stringify(collectOrderedImageTransactions(prevState.doc)) !== JSON.stringify(collectOrderedImageTransactions(candidateState.doc));
          if (imageChanged) {
            const inputType = lastInputType;
            if (imageFenceRevision === null && lastPreOpSnapshot === null) {
              if (!composing && serialize() !== base2) {
                lastInputType = pendingInputType;
                emitChangeIfNeeded();
                lastInputType = inputType;
              }
              const editorState = composing ? emittedEditorState : prevState;
              lastPreOpSnapshot = { revision: revision + 1, markdown: base2, editorState };
            }
            if (!inputType.startsWith("history") && tr.getMeta("addToHistory") !== false) {
              const sepState = prevState.apply(closeHistory(prevState.tr));
              candidateState = sepState.apply(tr);
            }
          }
          view.updateState(candidateState);
          if (tr.docChanged) docMutationVersion += 1;
          observeClipboardSelection();
          if (tr.docChanged) {
            if (!composing) {
              if (flushingDom || imageChanged || tr.getMeta("fastraImmediate") === true) {
                emitChangeIfNeeded();
              } else {
                scheduleEmitChange();
              }
            }
          } else if (tr.selectionSet) {
            notifyHistoryAndOutline();
          }
        }
      });
      tableEditorInstance = createTableEditor({
        view,
        schema,
        blocked: () => fenced || composing || failed,
        revision: () => revision,
        applyTransaction: (tr) => applyTransaction2(tr, { inputType: "editTable" }),
        report: () => reportTableContext(),
        fail: (reason) => postMessage({ kind: "tableError", session, reason })
      });
      tables = tableEditorInstance;
      return view;
    }
    function wrapAncestorChain(innerFragment, $pos, startDepth) {
      let current = innerFragment;
      const parent = $pos.parent;
      const leafAttrs = parent.attrs && "mdBlockId" in parent.attrs ? { ...parent.attrs, mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 } : parent.attrs;
      current = parent.type.create(leafAttrs, current);
      for (let d = startDepth; d >= 1; d--) {
        const anc = $pos.node(d);
        if (anc.type === schema.nodes.list_item) {
          current = anc.type.create({ ...anc.attrs }, current);
        } else if (anc.type === schema.nodes.bullet_list) {
          current = anc.type.create({ ...anc.attrs, mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 }, current);
        } else if (anc.type === schema.nodes.ordered_list) {
          const startOrder = Math.max(0, Number(anc.attrs.order ?? 1)) + $pos.index(d);
          current = anc.type.create({ ...anc.attrs, mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1, order: startOrder }, current);
        } else if (anc.type === schema.nodes.blockquote) {
          current = anc.type.create({ ...anc.attrs, mdContext: "", mdBlockId: null, mdBlockSub: 0, mdBlockTotal: 1 }, current);
        }
      }
      return Fragment.from(current);
    }
    function buildCopyFragment(slice2, selection) {
      if (!slice2.content.childCount) return slice2.content;
      const { $from, $to } = selection;
      const findCell = ($pos) => {
        for (let d = $pos.depth; d > 0; d--) {
          const t = $pos.node(d).type;
          if (t === schema.nodes.table_cell || t === schema.nodes.table_header) return $pos.before(d);
        }
        return null;
      };
      const fromCell = findCell($from);
      if (fromCell !== null && fromCell === findCell($to)) {
        if (slice2.content.childCount === 1 && (slice2.content.firstChild.type === schema.nodes.table_cell || slice2.content.firstChild.type === schema.nodes.table_header)) {
          return slice2.content.firstChild.content;
        }
        if (slice2.content.childCount === 1 && slice2.content.firstChild.type === schema.nodes.table_row) {
          const cell = slice2.content.firstChild.firstChild;
          if (cell) return cell.content;
        }
        if (slice2.content.childCount === 1 && slice2.content.firstChild.type === schema.nodes.table) {
          const cell = slice2.content.firstChild.firstChild?.firstChild;
          if (cell) return cell.content;
        }
        return slice2.content;
      }
      if ($from.sameParent($to)) {
        const parent = $from.parent;
        let hasContainerAncestor = false;
        for (let d = $from.depth - 1; d >= 1; d--) {
          const t = $from.node(d).type;
          if (t === schema.nodes.blockquote || t === schema.nodes.list_item || t === schema.nodes.bullet_list || t === schema.nodes.ordered_list) {
            hasContainerAncestor = true;
            break;
          }
        }
        const inlineContent = slice2.content.childCount === 1 && slice2.content.firstChild.isTextblock ? slice2.content.firstChild.content : slice2.content;
        if (parent.type === schema.nodes.heading || parent.type === schema.nodes.code_block || hasContainerAncestor) {
          return wrapAncestorChain(inlineContent, $from, $from.depth - 1);
        }
        if (slice2.openStart > 0 && slice2.openEnd > 0 && slice2.content.childCount === 1 && slice2.content.firstChild.type === schema.nodes.paragraph) {
          return inlineContent;
        }
        return slice2.content;
      }
      if (slice2.openStart > 0 && slice2.content.firstChild?.type === schema.nodes.ordered_list) {
        const children = [];
        slice2.content.forEach((child, _offset, idx) => {
          if (idx === 0 && child.type === schema.nodes.ordered_list) {
            let listAncestor = null;
            for (let d = 1; d < $from.depth; d++) {
              if ($from.node(d).type === schema.nodes.ordered_list) {
                listAncestor = { node: $from.node(d), index: $from.index(d) };
                break;
              }
            }
            if (listAncestor) {
              const startOrder = Math.max(0, Number(listAncestor.node.attrs.order ?? 1)) + listAncestor.index;
              children.push(child.type.create({ ...child.attrs, order: startOrder }, child.content, child.marks));
              return;
            }
          }
          children.push(child);
        });
        return Fragment.fromArray(children);
      }
      return slice2.content;
    }
    function serializeSliceMarkdown(contextFragment) {
      if (!contextFragment.childCount) return "";
      if (contextFragment.firstChild?.isInline) {
        return serializeInline(contextFragment, { opaqueSources });
      }
      const parts = [];
      contextFragment.forEach((child) => {
        if (child.isBlock) {
          if (child.type.name === "paragraph" && child.content.size === 0 && contextFragment.childCount > 1) {
            parts.push("  ");
          } else {
            parts.push(serializeBlockNode(child, { opaqueSources }));
          }
        }
      });
      return parts.filter((p) => p !== "").join("\n\n");
    }
    function handleCopyOrCut(event, isCut) {
      if (!view || fenced) return false;
      syncFromDOM();
      if (view.state.selection.empty) return false;
      const { from: from2, to } = view.state.selection;
      const slice2 = view.state.doc.slice(from2, to);
      const copyFragment = buildCopyFragment(slice2, view.state.selection);
      const holder = document.createElement("div");
      const domFrag = DOMSerializer.fromSchema(schema).serializeFragment(copyFragment, { document });
      holder.appendChild(domFrag);
      holder.querySelectorAll("li[data-task]").forEach((li) => {
        if (!li.querySelector(':scope > input[type="checkbox"]')) {
          const cb = document.createElement("input");
          cb.type = "checkbox";
          if (li.getAttribute("data-task") === "checked") cb.setAttribute("checked", "");
          li.prepend(cb);
        }
      });
      const markdown = serializeSliceMarkdown(copyFragment);
      const imageSources = Array.from(holder.querySelectorAll("img"), (im) => im.getAttribute("src"));
      const markEl = root?.querySelector("mark");
      if (markEl && typeof getComputedStyle === "function") {
        const style = getComputedStyle(markEl);
        holder.querySelectorAll("mark").forEach((m) => {
          m.style.backgroundColor = style.backgroundColor;
          m.style.color = style.color;
        });
      }
      holder.querySelectorAll(".fastra-visible-blank-line").forEach((n) => {
        if (!n.textContent.length) n.replaceWith(document.createElement("br"));
        else {
          n.classList.remove("fastra-visible-blank-line");
          if (!n.classList.length) n.removeAttribute("class");
        }
      });
      holder.querySelectorAll("*").forEach((n) => {
        for (const a of Array.from(n.attributes)) {
          if (a.name.startsWith("data-md-") || a.name.startsWith("data-fastra-") || a.name === "contenteditable") {
            n.removeAttribute(a.name);
          }
        }
      });
      event.preventDefault();
      event.stopPropagation();
      const first = slice2.content.childCount === 1 ? slice2.content.firstChild : null;
      const singleImage = first?.type === schema.nodes.image || first?.type === schema.nodes.paragraph && first.childCount === 1 && first.firstChild.type === schema.nodes.image;
      const plain = view.state.doc.textBetween(from2, to, "\n", "\n");
      const htmlStr = holder.innerHTML;
      const enc = new TextEncoder();
      if (clipboardLimit && [plain, htmlStr, markdown].some((v) => enc.encode(v).length > clipboardLimit)) {
        postMessage({ kind: "clipboardError", session, reason: "size" });
        return true;
      }
      const key = window.fastraVisual.bookmark();
      copiedHTML = holder;
      clipboardBookmark = key;
      updateFence();
      postCopyMessage({
        plain,
        html: htmlStr,
        markdown,
        imageSources,
        singleImage,
        session,
        bookmark: key,
        cut: isCut
      });
      return true;
    }
    function buildPasteSlice(htmlString) {
      const doc3 = root?.ownerDocument || document;
      const tpl = doc3.createElement("template");
      tpl.innerHTML = htmlString || "";
      const hasBlocks = !!tpl.content.querySelector("h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,pre,hr,table,div");
      const pCount = tpl.content.querySelectorAll("p").length;
      const onlyMultiBreakParagraph = pCount === 1 && (() => {
        const p = tpl.content.querySelector("p");
        return p.querySelectorAll("br").length >= 2 && !p.textContent.replace(/\u200b/g, "").length && !p.querySelector("img,[data-tex],[data-md-opaque]");
      })();
      if (!hasBlocks && pCount <= 1 && !onlyMultiBreakParagraph) {
        if (pCount === 1) {
          const p = tpl.content.querySelector("p");
          p.replaceWith(...p.childNodes);
        }
        const parsedInlineNodes = parseHTMLToNodes(tpl.innerHTML, { schema, ownerDocument: doc3 });
        const inlineRuns = [];
        for (const b of parsedInlineNodes) {
          if (b.type === schema.nodes.paragraph || b.isTextblock) {
            b.content.forEach((c) => inlineRuns.push(c));
          } else {
            inlineRuns.push(b);
          }
        }
        if (inlineRuns.length) {
          return new Slice(Fragment.fromArray(inlineRuns), 0, 0);
        }
      }
      const nodes2 = parseHTMLToNodes(htmlString, { schema, ownerDocument: doc3 });
      return nodes2.length ? new Slice(Fragment.fromArray(nodes2), 0, 0) : null;
    }
    function isCodeSelection({ $from, $to }) {
      return $from.sameParent($to) && $from.parent.type === schema.nodes.code_block;
    }
    function clipboardPlainText(html) {
      const nodes2 = parseHTMLToNodes(sanitizePasteHTML(html, document), { schema, ownerDocument: document });
      const fragment = Fragment.fromArray(nodes2);
      return fragment.textBetween(0, fragment.size, "\n", (node) => node.type === schema.nodes.hard_break ? "\n" : "");
    }
    function insertPlainText(selection, value) {
      const text = value.replace(/\r\n?|\n/g, "\n");
      if (!text) return false;
      const tr = closeHistory(view.state.tr.setSelection(selection));
      if (isCodeSelection(selection)) {
        tr.insertText(text);
      } else if (!text.includes("\n")) {
        tr.insertText(text.replaceAll("	", "\xA0\xA0\xA0\xA0"));
      } else {
        const marks2 = view.state.storedMarks || (selection.empty ? selection.$from.marks() : selection.$from.marksAcross(selection.$to) || []);
        const paragraphs = text.split("\n").map((line) => /^[ \t]*$/.test(line) ? schema.nodes.blank_line.create() : schema.nodes.paragraph.create(null, schema.text(line.replaceAll("	", "\xA0\xA0\xA0\xA0"), marks2)));
        tr.replaceSelection(Slice.maxOpen(Fragment.fromArray(paragraphs)));
      }
      if (!tr.docChanged) return false;
      applyTransaction2(tr.scrollIntoView(), { inputType: "insertFromPaste" });
      return true;
    }
    function runHistory(dir) {
      if (!view || fenced || failed || composing) return false;
      resumeDomObserverIfPaused();
      lastInputType = dir === "undo" ? "historyUndo" : "historyRedo";
      const fn = dir === "undo" ? undo : redo;
      const ok = fn(view.state, (tr) => applyTransaction2(tr, { inputType: lastInputType }));
      if (ok) emitChangeIfNeeded();
      else lastInputType = "";
      return ok;
    }
    function installDOMListeners(targetRoot) {
      if (!listenersInstalledOnRoot.has(targetRoot)) {
        listenersInstalledOnRoot.add(targetRoot);
        targetRoot.addEventListener(
          "keydown",
          (event) => {
            if (event.isComposing) return;
            if (tables?.rejectOversizedTabAtDOM(event)) {
              event.preventDefault();
              event.stopImmediatePropagation();
              try {
                view?.domObserver?.observer?.takeRecords?.();
                if (Array.isArray(view?.domObserver?.queue)) view.domObserver.queue.length = 0;
                view?.domObserver?.stop?.();
                domObserverPausedForOversizedTable = true;
              } catch (_) {
              }
              return;
            }
            resumeDomObserverIfPaused();
            const selChanged = syncFromDOM();
            if (!view?.hasFocus?.() || selChanged) {
              syncProseMirrorSelectionToDOM({ force: true });
            }
          },
          true
        );
        targetRoot.addEventListener("pointerdown", () => {
          resumeDomObserverIfPaused();
        });
        targetRoot.addEventListener("mousedown", (e) => {
          if (e.button === 0) {
            selectingWithMouse = true;
            mouseDragStart = { x: e.clientX, y: e.clientY };
            mouseDragMoved = false;
            mouseDragHadButtons = false;
            try {
              const coords = view?.posAtCoords?.({ left: e.clientX, top: e.clientY });
              mouseDragAnchor = coords && typeof coords.pos === "number" ? coords.pos : null;
            } catch (_) {
              mouseDragAnchor = null;
            }
          }
          clipboardSelectionGeneration++;
        });
        targetRoot.addEventListener("keydown", (event) => {
          if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown"].includes(event.key) || (event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "a") {
            clipboardSelectionGeneration++;
          }
          if (event.metaKey || event.ctrlKey || ["Enter", "Backspace", "Delete", "Tab"].includes(event.key)) {
            diagnostics.pushDiagnosticEvent("keydown", {
              key: sanitizeDiagnosticKey(event.key, !!(event.metaKey || event.ctrlKey)),
              meta: event.metaKey,
              ctrl: event.ctrlKey,
              shift: event.shiftKey,
              alt: event.altKey,
              sel: diagnostics.selectionSummary(view)
            });
          }
          if (!["Shift", "Alt", "Control", "Meta"].includes(event.key)) {
            if (selectingWithMouse) {
              selectingWithMouse = false;
              reportTableContext();
            }
          }
        });
      }
      if (!globalListenersInstalled) {
        globalListenersInstalled = true;
        window.addEventListener("pagehide", (event) => {
          if (event.persisted) return;
          clearPendingEmitTimer();
          tables?.destroy();
          view?.destroy();
          tables = null;
          view = null;
        });
        document.addEventListener(
          "mousemove",
          (e) => {
            if (!selectingWithMouse || fenced || composing || domObserverPausedForOversizedTable || !view || !root) return;
            if (e.buttons !== 0) {
              mouseDragHadButtons = true;
              return;
            }
            if (mouseDragHadButtons) {
              finishMouseSelection();
              return;
            }
            if (mouseDragAnchor === null || !mouseDragStart) return;
            if (!mouseDragMoved && Math.hypot(e.clientX - mouseDragStart.x, e.clientY - mouseDragStart.y) < 4) return;
            mouseDragMoved = true;
            try {
              const head = view.posAtCoords({ left: e.clientX, top: e.clientY });
              if (!head || typeof head.pos !== "number") return;
              const doc3 = view.state.doc;
              const $anchor = doc3.resolve(Math.max(0, Math.min(mouseDragAnchor, doc3.content.size)));
              const $head = doc3.resolve(Math.max(0, Math.min(head.pos, doc3.content.size)));
              const sel = TextSelection.between($anchor, $head);
              if (!view.state.selection.eq(sel)) {
                view.dispatch(view.state.tr.setSelection(sel).setMeta("addToHistory", false));
                syncProseMirrorSelectionToDOM({ force: true });
                reportTableContext();
              }
            } catch (_) {
            }
          },
          true
        );
        const finishMouseSelection = () => {
          if (selectingWithMouse) {
            const didSyntheticDrag = mouseDragMoved;
            selectingWithMouse = false;
            mouseDragAnchor = null;
            mouseDragStart = null;
            mouseDragMoved = false;
            if (tables) tables.selectingWithMouse = false;
            if (didSyntheticDrag) {
              syncProseMirrorSelectionToDOM({ force: true });
            } else if (!(view?.state?.selection instanceof NodeSelection)) {
              syncDOMSelectionToProseMirror();
            }
            reportTableContext();
            requestAnimationFrame(() => {
              if (!selectingWithMouse && !fenced && !composing && !domObserverPausedForOversizedTable) {
                if (didSyntheticDrag) {
                  syncProseMirrorSelectionToDOM({ force: true });
                } else if (!(view?.state?.selection instanceof NodeSelection)) {
                  syncDOMSelectionToProseMirror();
                }
                reportTableContext();
              }
            });
          }
        };
        document.addEventListener("mouseup", finishMouseSelection, true);
        document.addEventListener("pointercancel", finishMouseSelection, true);
        document.documentElement.addEventListener("mouseleave", finishMouseSelection);
        document.addEventListener("selectionchange", () => {
          if (initializing || fenced || composing || selectingWithMouse || domObserverPausedForOversizedTable || !view || !root) return;
          if (view.state.selection instanceof NodeSelection) return;
          const winSel = document.getSelection?.();
          if (!winSel || !winSel.rangeCount || !root.contains(winSel.anchorNode)) return;
          syncDOMSelectionToProseMirror();
          reportTableContext();
        });
        window.addEventListener("blur", finishMouseSelection);
        window.addEventListener(
          "scroll",
          () => {
            if (viewportRestoring || viewportPending) return;
            viewportPending = true;
            requestAnimationFrame(() => {
              viewportPending = false;
              reportViewport();
            });
          },
          { passive: true }
        );
        for (const t of ["wheel", "pointerdown", "keydown"]) {
          window.addEventListener(
            t,
            () => {
              viewportGeneration++;
              viewportRestoring = false;
            },
            { passive: true }
          );
        }
        if (!window.__fastraDiagnosticErrorsInstalled) {
          window.__fastraDiagnosticErrorsInstalled = true;
          window.addEventListener("error", (ev) => {
            diagnostics.recordAnomaly("js-error", String(ev.message || "Unknown JS error"), {
              lineno: ev.lineno,
              colno: ev.colno
            });
          });
          window.addEventListener("unhandledrejection", (ev) => {
            diagnostics.recordAnomaly("js-rejection", String(ev.reason || "Unhandled promise rejection"));
          });
        }
      }
    }
    window.fastraVisual = {
      tableContext() {
        return tables?.context?.() || null;
      },
      tableState() {
        return { revision, context: toolbarTableContext() };
      },
      tableCommand(name, value, token) {
        if (name !== "insertTable") {
          const winSel = document.getSelection?.();
          const aNode = winSel?.anchorNode;
          const tableEl = (aNode?.nodeType === 1 ? aNode : aNode?.parentElement)?.closest?.("table");
          if (tableEl && root?.contains(tableEl) && (tableEl.getAttribute("data-md-table") !== "gfm" || tableEl.querySelector("[colspan],[rowspan],table"))) {
            return { ok: false, reason: "html" };
          }
        }
        syncFromDOM();
        view?.focus?.();
        const res = tables?.command?.(name, value, token);
        emitChangeIfNeeded();
        return res;
      },
      canUndo() {
        return view ? getHistoryState(view.state).canUndo : false;
      },
      canRedo() {
        return view ? getHistoryState(view.state).canRedo : false;
      },
      historyState() {
        return view ? getHistoryState(view.state) : { canUndo: false, canRedo: false, undoDepth: 0, redoDepth: 0 };
      },
      undo() {
        return runHistory("undo");
      },
      redo() {
        return runHistory("redo");
      },
      setFailed() {
        failed = true;
        updateFence();
      },
      outlinePosition,
      outlineSnapshot() {
        const nodes2 = outlineHeadings();
        if (nodes2.length > 1e4) return { ok: false, reason: "limit" };
        const enc = new TextEncoder();
        let bytes = 0;
        const headings = [];
        for (const node of nodes2) {
          const title = node.textContent.trim();
          const len = enc.encode(title).length;
          bytes += len;
          if (len > 16384 || bytes > 2097152) return { ok: false, reason: "limit" };
          headings.push({ level: Number(node.tagName.slice(1)), title });
        }
        return { ok: true, session, revision, index: outlinePosition(), headings };
      },
      revealHeading(index) {
        if (composing || !view) return false;
        const headings = outlineHeadings();
        const heading = index >= 0 ? headings[index] : null;
        if (index >= 0 && !heading) return false;
        view.focus();
        if (heading) {
          try {
            const pos = view.posAtDOM(heading, 0);
            applyTransaction2(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(pos))), { allowFenced: true });
          } catch (_) {
          }
          heading.scrollIntoView?.({ block: "center" });
        } else {
          applyTransaction2(view.state.tr.setSelection(Selection.atStart(view.state.doc)), { allowFenced: true });
          window.scrollTo?.(0, 0);
        }
        return true;
      },
      async start(configuration) {
        if (failed) return false;
        initializing = true;
        const nextRoot = document.getElementById("fastra-visual");
        if (session !== configuration.session) {
          nativeActionIDs.clear();
          originals.clear();
          contexts.clear();
          unresolvedImageSources.clear();
        }
        trackUnresolvedImages = configuration.trackUnresolvedImages === true;
        const sameMountedSession = !!view && view.dom === nextRoot && root === nextRoot && session === configuration.session && nextRoot?.classList?.contains("ProseMirror");
        session = configuration.session;
        root = nextRoot;
        lastReportedTableKey = null;
        updateFence();
        const until = Date.now() + 5e3;
        while (!document.documentElement.hasAttribute("data-fastra-enhanced")) {
          if (Date.now() >= until) {
            failed = true;
            initializing = false;
            updateFence();
            return false;
          }
          await new Promise((r) => setTimeout(r, 10));
        }
        clipboardLimit = configuration.clipboardLimit || 0;
        sourceReplacementEnabled = configuration.sourceReplacements === true;
        if (sourceReplacementEnabled) {
          sourceContextBytes = new TextEncoder().encode(configuration.markdown).length + root.innerHTML.length + 256;
        }
        if (sameMountedSession && serialize() === configuration.markdown) {
          publishedMutationVersion = docMutationVersion;
          await restoreViewport(configuration.viewport);
          initializing = false;
          updateFence();
          notifyHistoryAndOutline();
          return true;
        }
        base2 = configuration.markdown;
        originals.clear();
        contexts.clear();
        Object.keys(opaqueSources).forEach((k) => delete opaqueSources[k]);
        Object.assign(opaqueSources, configuration.opaqueSources || {});
        root.querySelectorAll("img").forEach((img) => {
          const token = img.getAttribute("src")?.split("/").pop();
          const tx = configuration.imageTransactions?.[token];
          if (tx) img.dataset.mdImageTransaction = tx;
        });
        const { doc: doc3, parsedGroups } = parseDocumentContainer(root, configuration.blocks, {
          schema,
          mdContext: "",
          ownerDocument: document
        });
        buildContextEntry(configuration, "", parsedGroups, originals, contexts, opaqueSources);
        if (trackUnresolvedImages) doc3.descendants(rememberUnresolvedImage);
        createEditorView(doc3, root);
        root.setAttribute("role", "textbox");
        root.setAttribute("aria-multiline", "true");
        installDOMListeners(root);
        lastImageTransactions = JSON.stringify(collectOrderedImageTransactions(view.state.doc));
        emittedEditorState = view.state;
        publishedMutationVersion = docMutationVersion;
        diagnostics.pushDiagnosticEvent("start", {
          blockCount: (configuration.blocks || []).length,
          markdownLen: base2.length,
          empty: !base2.length
        });
        if (serialize() !== base2) {
          failed = true;
          initializing = false;
          updateFence();
          return false;
        }
        await restoreViewport(configuration.viewport);
        initializing = false;
        updateFence();
        root.focus({ preventScroll: true });
        if (configuration.viewport) {
          await restoreViewport(configuration.viewport);
        }
        notifyHistoryAndOutline();
        return true;
      },
      command(command, value) {
        if (fenced || failed || composing || !view) return false;
        resumeDomObserverIfPaused();
        if (command === "delete") {
          lastInputType = "deleteContentBackward";
        } else if (command !== "undo" && command !== "redo") {
          lastInputType = "";
        }
        syncFromDOM();
        const beforeTextLen = diagnostics.visibleTextLength();
        const selBefore = diagnostics.selectionSummary(view);
        const hadNonEmptySelection = !view.state.selection.empty;
        diagnostics.pushDiagnosticEvent("command", { command, beforeTextLen, sel: selBefore });
        try {
          const res = executeVisualCommand(view, command, value, {
            schema,
            tableEditor: tables,
            postMessage,
            session,
            onHistoryCommand: (dir) => runHistory(dir)
          });
          if (!res.executed) {
            if (!["protected", "table", "idempotent", "empty-history"].includes(res.reason)) {
              diagnostics.recordAnomaly("command-noop", `Command ${command} had no effect`, { command });
            }
            return false;
          }
          syncProseMirrorSelectionToDOM({ force: true });
          const afterTextLen = diagnostics.visibleTextLength();
          const checkTextLoss = [
            "bold",
            "italic",
            "code",
            "highlight",
            "strike",
            "heading1",
            "heading2",
            "heading3",
            "heading4",
            "heading5",
            "heading6",
            "plainParagraph",
            "bulletList",
            "orderedList",
            "taskList",
            "quote",
            "link"
          ].includes(command) || command === "hardBreak" && !hadNonEmptySelection;
          emitChangeIfNeeded();
          if (checkTextLoss && afterTextLen < beforeTextLen) {
            diagnostics.recordAnomaly(
              "unexpected-text-loss",
              `Command ${command} reduced visible text (${beforeTextLen} -> ${afterTextLen})`,
              { command, beforeTextLen, afterTextLen }
            );
          }
          return true;
        } catch (err) {
          diagnostics.recordAnomaly("command-exception", `Command ${command} threw: ${err?.message || err}`, { command });
          throw err;
        }
      },
      refreshImageSources(addresses, transactions, expectedSession = session) {
        if (!view || expectedSession !== session) return;
        for (const [srcKey, url] of Object.entries(addresses || {})) {
          if (typeof url === "string" && url) imageUrlOverrides.set(srcKey, url);
        }
        const txMap = transactions && !Array.isArray(transactions) && typeof transactions === "object" ? transactions : null;
        const txSet = Array.isArray(transactions) ? new Set(transactions) : null;
        const tr = view.state.tr.setMeta("addToHistory", false).setMeta("fastraAllowFenced", true);
        view.state.doc.descendants((node, pos) => {
          if (node.type.name === "image") {
            const mdSrc = node.attrs.mdSrc;
            const oldSrc = node.attrs.src;
            const allowedBySet = !txSet || node.attrs.imageTransaction && txSet.has(node.attrs.imageTransaction);
            const nextTx = mdSrc && txMap?.[mdSrc] || node.attrs.imageTransaction;
            const mappedSrc = allowedBySet ? addresses?.[oldSrc] || mdSrc && addresses?.[mdSrc] || oldSrc : oldSrc;
            if (oldSrc && mappedSrc && mappedSrc !== oldSrc) {
              imageUrlOverrides.set(oldSrc, mappedSrc);
            }
            if (nextTx !== node.attrs.imageTransaction || mappedSrc !== oldSrc) {
              tr.setNodeMarkup(pos, null, {
                ...node.attrs,
                src: mappedSrc,
                imageTransaction: nextTx
              });
            }
          }
          return true;
        });
        if (tr.docChanged) view.dispatch(tr);
        else applyDomImageOverridesOnImages(view.state.doc);
      },
      updateLocalImages(mapping) {
        if (!view || !mapping) return;
        const tr = view.state.tr.setMeta("addToHistory", false).setMeta("fastraAllowFenced", true);
        view.state.doc.descendants((node, pos) => {
          if (node.type.name !== "image") return true;
          const token = extractUriToken(node.attrs.src);
          let entry = token ? mapping[token] : null;
          if (entry && typeof entry === "object" && entry.raw && node.attrs.mdSrc && entry.raw !== node.attrs.mdSrc) {
            entry = null;
          }
          const nextUri = typeof entry === "string" ? entry : entry?.uri;
          if (nextUri && nextUri !== node.attrs.src) {
            tr.setNodeMarkup(pos, null, { ...node.attrs, src: nextUri });
          }
          return true;
        });
        if (tr.docChanged) view.dispatch(tr);
      },
      exportClipboardHTML(key, replacements) {
        if (key !== clipboardBookmark || !copiedHTML) return null;
        const copy2 = copiedHTML.cloneNode(true);
        for (const img of copy2.querySelectorAll("img")) {
          const data = replacements?.[img.getAttribute("src")];
          if (!data?.startsWith("data:image/")) return null;
          img.setAttribute("src", data);
        }
        return copy2.innerHTML;
      },
      caretClipboard(x, y) {
        if (!view) return null;
        const coords = view.posAtCoords({ left: x, top: y });
        if (!coords) return null;
        applyTransaction2(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(coords.pos))), { allowFenced: true });
        return window.fastraVisual.bookmarkClipboard();
      },
      caret(x, y) {
        if (!view) return null;
        const coords = view.posAtCoords({ left: x, top: y });
        if (!coords) return null;
        applyTransaction2(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(coords.pos))), { allowFenced: true });
        return window.fastraVisual.bookmark();
      },
      bookmark(existing) {
        if (!view) return null;
        if (existing) return bookmarks.has(existing) ? existing : null;
        syncFromDOM();
        const key = String(++bookmarkID);
        bookmarks.set(key, {
          selectionJSON: view.state.selection.toJSON(),
          base: serialize()
        });
        return key;
      },
      bookmarkClipboard() {
        const key = window.fastraVisual.bookmark();
        const saved = bookmarks.get(key);
        if (saved) {
          saved.clipboardSelection = observeClipboardSelection();
          saved.clipboardSelectionGeneration = clipboardSelectionGeneration;
        }
        return key;
      },
      validateClipboardBookmark(key) {
        const saved = bookmarks.get(key);
        return !!saved && saved.base === serialize() && currentClipboardSelection(saved);
      },
      clipboardState() {
        const imageTransactions = view ? collectImageTransactions(view.state.doc) : [];
        return { markdown: serialize(), revision, imageTransactions };
      },
      discardBookmark(key) {
        return bookmarks.delete(key);
      },
      insertBookmarked(key, html, atoms, transaction, imageSources, singleLine = false, imageEnding = null) {
        if (fenced || failed || composing || !view) return false;
        const saved = bookmarks.get(key);
        bookmarks.delete(key);
        if (!saved || saved.base !== serialize() || !currentClipboardSelection(saved)) return false;
        const template = document.createElement("template");
        template.innerHTML = html;
        if (transaction) {
          template.content.querySelectorAll("img").forEach((n) => {
            const src = n.getAttribute("src");
            if (!imageSources?.includes(src)) return;
            n.dataset.mdSrc = n.dataset.mdSrc || src;
            n.dataset.mdImageTransaction = transaction;
            if (imageEnding === "crlf" || imageEnding === "cr") n.dataset.mdImageEnding = imageEnding;
          });
        }
        const sel = Selection.fromJSON(view.state.doc, saved.selectionJSON);
        if (isCodeSelection(sel)) {
          if (transaction && imageSources?.length) return false;
          return insertPlainText(sel, clipboardPlainText(html));
        }
        const slice2 = buildPasteSlice(template.innerHTML);
        if (!slice2) return false;
        const tr = closeHistory(view.state.tr.setSelection(sel));
        if (singleLine && tables?.context?.()) {
          const { $from, $to } = sel;
          if (tables.context().reason || !$from.sameParent($to) || ![schema.nodes.table_cell, schema.nodes.table_header].includes($from.parent.type) || !$from.parent.type.validContent(slice2.content)) return false;
        }
        tr.replaceSelection(slice2).scrollIntoView();
        if (!tr.docChanged) return false;
        Object.assign(opaqueSources, atoms || {});
        applyTransaction2(tr, { inputType: "insertFromPaste" });
        return true;
      },
      async replaceSource(expected, html, configuration, prefix) {
        if (!sourceReplacementEnabled || !view) return "unsupported";
        if (composing || fenced) return "busy";
        if (serialize() !== expected) return "stale";
        const cost = new TextEncoder().encode(configuration.markdown).length + new TextEncoder().encode(html).length + 256;
        if (contexts.has(prefix) || sourceContextBytes + cost > MAX_SOURCE_CONTEXT_BYTES) return "limit";
        const holder = document.createElement("div");
        holder.innerHTML = html;
        const ownedImages = /* @__PURE__ */ new Map();
        view.state.doc.descendants((n) => {
          if (n.type === schema.nodes.image && n.attrs.mdSrc && n.attrs.imageTransaction) {
            ownedImages.set(n.attrs.mdSrc, n.attrs.imageTransaction);
          }
          return true;
        });
        holder.querySelectorAll("img[data-md-src]").forEach((n) => {
          const tx = ownedImages.get(n.getAttribute("data-md-src"));
          if (tx) n.dataset.mdImageTransaction = tx;
        });
        if (holder.querySelector("pre > code.language-mermaid") && window.fastraEnhanceMarkdown) {
          const owner = view;
          const ownerSession = session;
          holder.style.cssText = "position:fixed;left:-100000px;visibility:hidden;pointer-events:none";
          document.body.append(holder);
          try {
            await window.fastraEnhanceMarkdown(holder);
          } finally {
            holder.remove();
          }
          if (owner !== view || ownerSession !== session || composing || fenced || serialize() !== expected || contexts.has(prefix) || sourceContextBytes + cost > MAX_SOURCE_CONTEXT_BYTES) return "stale";
        }
        const { doc: parsedDoc, parsedGroups } = parseDocumentContainer(holder, configuration.blocks, {
          schema,
          mdContext: prefix,
          ownerDocument: document
        });
        const trialContexts = new Map(contexts);
        const trialOriginals = new Map(originals);
        const trialOpaque = Object.assign(/* @__PURE__ */ Object.create(null), opaqueSources);
        buildContextEntry(configuration, prefix, parsedGroups, trialOriginals, trialContexts, trialOpaque);
        const trial = serializeDocument(parsedDoc, {
          contexts: trialContexts,
          originals: trialOriginals,
          opaqueSources: trialOpaque
        });
        if (trial !== configuration.markdown) {
          return "incomplete";
        }
        const confirmedContext = trialContexts.get(prefix);
        contexts.set(prefix, confirmedContext);
        for (const [k, v] of trialOriginals.entries()) originals.set(k, v);
        Object.assign(opaqueSources, trialOpaque);
        sourceContextBytes += cost;
        const prevDoc = view.state.doc;
        const tr = view.state.tr;
        tr.replaceWith(0, prevDoc.content.size, parsedDoc.content);
        tr.setDocAttribute("sourceContext", prefix);
        tr.setSelection(Selection.atStart(tr.doc));
        applyTransaction2(closeHistory(tr), { inputType: "replaceSource" });
        if (serialize() !== configuration.markdown) {
          actionFenced = true;
          updateFence();
          return "insert";
        }
        return true;
      },
      requestClipboardCopy(cut = false) {
        if (!view) return;
        syncDOMSelectionToProseMirror();
        view.focus();
        (view.dom || root)?.dispatchEvent(new Event(cut ? "cut" : "copy", { bubbles: true, cancelable: true }));
      },
      requestClipboardPaste(plain = false) {
        if (!fenced) {
          postMessage({
            kind: "linuxPaste",
            session,
            bookmark: window.fastraVisual.bookmarkClipboard(),
            plain
          });
        }
      },
      inspectClipboardHTML(html) {
        const cleaned = inspectAndCleanClipboardHTML(html, true, document);
        if (cleaned.ok && cleaned.images.length) {
          const nodes2 = parseHTMLToNodes(cleaned.html, { schema, ownerDocument: document });
          const doc3 = schema.nodes.doc.create(null, nodes2.length ? nodes2 : void 0);
          const markdown = serializeDocument(doc3, { contexts: /* @__PURE__ */ new Map(), originals: /* @__PURE__ */ new Map(), opaqueSources });
          return {
            ok: true,
            markdown,
            url: "file:///fastra-html-clipboard/Clipboard.md",
            images: cleaned.images
          };
        }
        return cleaned;
      },
      insertClipboardHTML(key, html) {
        const cleaned = inspectAndCleanClipboardHTML(html, false, document);
        if (!cleaned.ok) {
          bookmarks.delete(key);
          return cleaned;
        }
        return {
          ok: window.fastraVisual.insertBookmarked(key, cleaned.html, {}, null, [], false),
          reason: "stale"
        };
      },
      insertClipboardText(key, text) {
        const saved = bookmarks.get(key);
        bookmarks.delete(key);
        if (fenced || failed || composing || !view || !saved || saved.base !== serialize() || !currentClipboardSelection(saved)) return false;
        const sel = Selection.fromJSON(view.state.doc, saved.selectionJSON);
        if (!text) return false;
        if (!view.state.selection.eq(sel)) view.dispatch(view.state.tr.setSelection(sel));
        const tableResult = tables?.pasteText(text);
        return tableResult ?? insertPlainText(sel, text);
      },
      cancelClipboard() {
        if (clipboardBookmark !== null) {
          window.fastraVisual.completeClipboard(clipboardBookmark, false, false);
        }
      },
      completeClipboard(key, cut, succeeded) {
        if (key !== clipboardBookmark || !view) return false;
        const saved = bookmarks.get(key);
        bookmarks.delete(key);
        const unchanged = saved && saved.base === serialize();
        copiedHTML = null;
        clipboardBookmark = null;
        updateFence();
        if (cut && succeeded && unchanged) {
          const sel = Selection.fromJSON(view.state.doc, saved.selectionJSON);
          if (!sel.empty) {
            applyTransaction2(view.state.tr.setSelection(sel).deleteSelection().scrollIntoView(), { inputType: "deleteByCut" });
          }
        }
        return !!unchanged;
      },
      async updateStyle(font, size, dark) {
        document.body.style.setProperty("--fastra-copy-border", dark ? "#484848" : "#D7D7D7");
        document.body.style.setProperty("--fastra-copy-background", dark ? "#333333" : "#ECECEC");
        let sheet = document.getElementById("fastra-visual-style");
        if (!sheet) {
          sheet = document.createElement("style");
          sheet.id = "fastra-visual-style";
          document.head.append(sheet);
        }
        const family = font === "System" ? "-apple-system, BlinkMacSystemFont, sans-serif" : `${JSON.stringify(font)}, -apple-system, sans-serif`;
        sheet.textContent = `body{font-family:${family};font-size:${size}px;color:${dark ? "#F2F2F2" : "#363636"};background:${dark ? "#171717" : "#FFFFFF"}}h1,h2,h3,h4,h5,h6{color:inherit}blockquote,pre.mermaid-error::before{color:${dark ? "#A8A8A8" : "#737373"}}a{color:${dark ? "#8BB7F2" : "#3F69A8"}}code,pre{background:${dark ? "#333333" : "#ECECEC"}}td,th,blockquote,hr{border-color:${dark ? "#484848" : "#D7D7D7"}}mark{background:${dark ? "#665200" : "#FFEE9A"};color:inherit}`;
        window.fastraMarkdownPresentation?.update?.();
        await window.fastraUpdateMarkdownTheme?.(root, dark);
        window.fastraMarkdownPresentation?.update?.();
      },
      prepareAction(expectedSession, actionID, retryAfterComposition = false) {
        const isNative = arguments.length !== 0;
        if (isNative && (arguments.length < 2 || arguments.length > 3 || expectedSession !== session || typeof actionID !== "string" || !actionID.length || nativeActionIDs.has(actionID))) {
          return null;
        }
        if (initializing || failed) return null;
        if (composing) {
          if (retryAfterComposition) notifyCompositionEnd = true;
          return { composing: true };
        }
        syncFromDOM();
        emitChangeIfNeeded();
        if (isNative) nativeActionIDs.add(actionID);
        else actionFenced = true;
        if (clipboardBookmark !== null) {
          bookmarks.delete(clipboardBookmark);
          clipboardBookmark = null;
        }
        updateFence();
        const imageTransactions = view ? collectImageTransactions(view.state.doc) : [];
        const snapshot = {
          markdown: serialize(),
          revision,
          imageTransactions,
          inputType: emittedInputType,
          imageFenceRevision,
          viewport: viewportPosition(),
          historyState: view ? getHistoryState(view.state) : { canUndo: false, canRedo: false, undoDepth: 0, redoDepth: 0 }
        };
        if (isNative) {
          snapshot.session = session;
          snapshot.actionID = actionID;
          if (trackUnresolvedImages) snapshot.unresolvedImageSources = [...unresolvedImageSources];
        }
        return snapshot;
      },
      compareSaveAppearance(expectedSession, actionID, expectedRevision, html) {
        if (expectedSession !== session || !nativeActionIDs.has(actionID) || revision !== expectedRevision) return null;
        return diagnostics.compareSave(html);
      },
      inspectAppearance(expectedSession, expectedRevision, html) {
        if (expectedSession !== session || revision !== expectedRevision || composing || pendingEmitTimer !== null || docMutationVersion !== publishedMutationVersion) return null;
        return diagnostics.inspect(html);
      },
      diagnosticReport(includeContent = false) {
        return diagnostics.report(includeContent);
      },
      completeAction(expectedSession, actionID) {
        if (expectedSession !== session) return;
        if (arguments.length === 1) {
          actionFenced = false;
        } else {
          if (arguments.length !== 2 || typeof actionID !== "string" || !actionID.length || !nativeActionIDs.delete(actionID)) {
            return;
          }
        }
        updateFence();
      },
      completeImageAction(expectedSession, expectedRevision) {
        if (expectedSession !== session || expectedRevision !== imageFenceRevision) return;
        imageFenceRevision = null;
        lastPreOpSnapshot = null;
        updateFence();
      },
      rollbackImageChange(expectedRevision, previous) {
        if (!view || expectedRevision !== imageFenceRevision) return false;
        if (lastPreOpSnapshot?.revision === expectedRevision && lastPreOpSnapshot.markdown === previous) {
          view.updateState(lastPreOpSnapshot.editorState);
          emittedEditorState = view.state;
          publishedMutationVersion = docMutationVersion;
          base2 = previous;
          lastImageTransactions = JSON.stringify(collectOrderedImageTransactions(view.state.doc));
          lastPreOpSnapshot = null;
          lastInputType = "";
          updateFence();
          notifyHistoryAndOutline();
          return true;
        }
        return false;
      },
      viewport: viewportPosition,
      markdown: serialize,
      flush: () => {
        flushingDom = true;
        try {
          syncFromDOM();
          if (view && root && (fenced || !view.editable)) {
            const liveTx = new Set(
              Array.from(root.querySelectorAll("img[data-md-image-transaction]"), (n) => n.dataset.mdImageTransaction)
            );
            const missingRanges = [];
            view.state.doc.descendants((node, pos) => {
              if (node.type === schema.nodes.image && node.attrs.imageTransaction && !liveTx.has(node.attrs.imageTransaction)) {
                missingRanges.push([pos, pos + node.nodeSize]);
              }
              return true;
            });
            if (missingRanges.length) {
              const tr = view.state.tr;
              for (let i = missingRanges.length - 1; i >= 0; i--) {
                tr.delete(missingRanges[i][0], missingRanges[i][1]);
              }
              applyTransaction2(tr, { allowFenced: true });
            }
          }
        } finally {
          flushingDom = false;
        }
        emitChangeIfNeeded();
      }
    };
    return window.fastraVisual;
  }

  // src/index.js
  installFastraVisualBridge();
})();

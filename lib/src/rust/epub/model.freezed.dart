// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$BlockKind {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind()';
}


}

/// @nodoc
class $BlockKindCopyWith<$Res>  {
$BlockKindCopyWith(BlockKind _, $Res Function(BlockKind) __);
}


/// Adds pattern-matching-related methods to [BlockKind].
extension BlockKindPatterns on BlockKind {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( BlockKind_Root value)?  root,TResult Function( BlockKind_Paragraph value)?  paragraph,TResult Function( BlockKind_Heading value)?  heading,TResult Function( BlockKind_List value)?  list,TResult Function( BlockKind_ListItem value)?  listItem,TResult Function( BlockKind_Blockquote value)?  blockquote,TResult Function( BlockKind_Pre value)?  pre,TResult Function( BlockKind_Image value)?  image,TResult Function( BlockKind_Inline value)?  inline,required TResult orElse(),}){
final _that = this;
switch (_that) {
case BlockKind_Root() when root != null:
return root(_that);case BlockKind_Paragraph() when paragraph != null:
return paragraph(_that);case BlockKind_Heading() when heading != null:
return heading(_that);case BlockKind_List() when list != null:
return list(_that);case BlockKind_ListItem() when listItem != null:
return listItem(_that);case BlockKind_Blockquote() when blockquote != null:
return blockquote(_that);case BlockKind_Pre() when pre != null:
return pre(_that);case BlockKind_Image() when image != null:
return image(_that);case BlockKind_Inline() when inline != null:
return inline(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( BlockKind_Root value)  root,required TResult Function( BlockKind_Paragraph value)  paragraph,required TResult Function( BlockKind_Heading value)  heading,required TResult Function( BlockKind_List value)  list,required TResult Function( BlockKind_ListItem value)  listItem,required TResult Function( BlockKind_Blockquote value)  blockquote,required TResult Function( BlockKind_Pre value)  pre,required TResult Function( BlockKind_Image value)  image,required TResult Function( BlockKind_Inline value)  inline,}){
final _that = this;
switch (_that) {
case BlockKind_Root():
return root(_that);case BlockKind_Paragraph():
return paragraph(_that);case BlockKind_Heading():
return heading(_that);case BlockKind_List():
return list(_that);case BlockKind_ListItem():
return listItem(_that);case BlockKind_Blockquote():
return blockquote(_that);case BlockKind_Pre():
return pre(_that);case BlockKind_Image():
return image(_that);case BlockKind_Inline():
return inline(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( BlockKind_Root value)?  root,TResult? Function( BlockKind_Paragraph value)?  paragraph,TResult? Function( BlockKind_Heading value)?  heading,TResult? Function( BlockKind_List value)?  list,TResult? Function( BlockKind_ListItem value)?  listItem,TResult? Function( BlockKind_Blockquote value)?  blockquote,TResult? Function( BlockKind_Pre value)?  pre,TResult? Function( BlockKind_Image value)?  image,TResult? Function( BlockKind_Inline value)?  inline,}){
final _that = this;
switch (_that) {
case BlockKind_Root() when root != null:
return root(_that);case BlockKind_Paragraph() when paragraph != null:
return paragraph(_that);case BlockKind_Heading() when heading != null:
return heading(_that);case BlockKind_List() when list != null:
return list(_that);case BlockKind_ListItem() when listItem != null:
return listItem(_that);case BlockKind_Blockquote() when blockquote != null:
return blockquote(_that);case BlockKind_Pre() when pre != null:
return pre(_that);case BlockKind_Image() when image != null:
return image(_that);case BlockKind_Inline() when inline != null:
return inline(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  root,TResult Function()?  paragraph,TResult Function( int field0)?  heading,TResult Function()?  list,TResult Function()?  listItem,TResult Function()?  blockquote,TResult Function()?  pre,TResult Function()?  image,TResult Function()?  inline,required TResult orElse(),}) {final _that = this;
switch (_that) {
case BlockKind_Root() when root != null:
return root();case BlockKind_Paragraph() when paragraph != null:
return paragraph();case BlockKind_Heading() when heading != null:
return heading(_that.field0);case BlockKind_List() when list != null:
return list();case BlockKind_ListItem() when listItem != null:
return listItem();case BlockKind_Blockquote() when blockquote != null:
return blockquote();case BlockKind_Pre() when pre != null:
return pre();case BlockKind_Image() when image != null:
return image();case BlockKind_Inline() when inline != null:
return inline();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  root,required TResult Function()  paragraph,required TResult Function( int field0)  heading,required TResult Function()  list,required TResult Function()  listItem,required TResult Function()  blockquote,required TResult Function()  pre,required TResult Function()  image,required TResult Function()  inline,}) {final _that = this;
switch (_that) {
case BlockKind_Root():
return root();case BlockKind_Paragraph():
return paragraph();case BlockKind_Heading():
return heading(_that.field0);case BlockKind_List():
return list();case BlockKind_ListItem():
return listItem();case BlockKind_Blockquote():
return blockquote();case BlockKind_Pre():
return pre();case BlockKind_Image():
return image();case BlockKind_Inline():
return inline();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  root,TResult? Function()?  paragraph,TResult? Function( int field0)?  heading,TResult? Function()?  list,TResult? Function()?  listItem,TResult? Function()?  blockquote,TResult? Function()?  pre,TResult? Function()?  image,TResult? Function()?  inline,}) {final _that = this;
switch (_that) {
case BlockKind_Root() when root != null:
return root();case BlockKind_Paragraph() when paragraph != null:
return paragraph();case BlockKind_Heading() when heading != null:
return heading(_that.field0);case BlockKind_List() when list != null:
return list();case BlockKind_ListItem() when listItem != null:
return listItem();case BlockKind_Blockquote() when blockquote != null:
return blockquote();case BlockKind_Pre() when pre != null:
return pre();case BlockKind_Image() when image != null:
return image();case BlockKind_Inline() when inline != null:
return inline();case _:
  return null;

}
}

}

/// @nodoc


class BlockKind_Root extends BlockKind {
  const BlockKind_Root(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Root);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.root()';
}


}




/// @nodoc


class BlockKind_Paragraph extends BlockKind {
  const BlockKind_Paragraph(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Paragraph);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.paragraph()';
}


}




/// @nodoc


class BlockKind_Heading extends BlockKind {
  const BlockKind_Heading(this.field0): super._();
  

 final  int field0;

/// Create a copy of BlockKind
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BlockKind_HeadingCopyWith<BlockKind_Heading> get copyWith => _$BlockKind_HeadingCopyWithImpl<BlockKind_Heading>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Heading&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'BlockKind.heading(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $BlockKind_HeadingCopyWith<$Res> implements $BlockKindCopyWith<$Res> {
  factory $BlockKind_HeadingCopyWith(BlockKind_Heading value, $Res Function(BlockKind_Heading) _then) = _$BlockKind_HeadingCopyWithImpl;
@useResult
$Res call({
 int field0
});




}
/// @nodoc
class _$BlockKind_HeadingCopyWithImpl<$Res>
    implements $BlockKind_HeadingCopyWith<$Res> {
  _$BlockKind_HeadingCopyWithImpl(this._self, this._then);

  final BlockKind_Heading _self;
  final $Res Function(BlockKind_Heading) _then;

/// Create a copy of BlockKind
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(BlockKind_Heading(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class BlockKind_List extends BlockKind {
  const BlockKind_List(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_List);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.list()';
}


}




/// @nodoc


class BlockKind_ListItem extends BlockKind {
  const BlockKind_ListItem(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_ListItem);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.listItem()';
}


}




/// @nodoc


class BlockKind_Blockquote extends BlockKind {
  const BlockKind_Blockquote(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Blockquote);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.blockquote()';
}


}




/// @nodoc


class BlockKind_Pre extends BlockKind {
  const BlockKind_Pre(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Pre);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.pre()';
}


}




/// @nodoc


class BlockKind_Image extends BlockKind {
  const BlockKind_Image(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Image);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.image()';
}


}




/// @nodoc


class BlockKind_Inline extends BlockKind {
  const BlockKind_Inline(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is BlockKind_Inline);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'BlockKind.inline()';
}


}




// dart format on

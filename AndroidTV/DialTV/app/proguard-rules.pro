-dontobfuscate
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
# kotlinx.serialization: keep generated serializers of Dial's own models
-keep,includedescriptorclasses class app.dial.**$$serializer { *; }
-keepclassmembers class app.dial.** { *** Companion; }
-keepclasseswithmembers class app.dial.** { kotlinx.serialization.KSerializer serializer(...); }
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**

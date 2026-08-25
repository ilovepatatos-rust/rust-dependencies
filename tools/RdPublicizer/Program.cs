using System.Text.RegularExpressions;
using Mono.Cecil;

namespace RdPublicizer;

internal static class Program
{
    private static readonly string[] CarbonAssemblies =
    [
        "Assembly-CSharp.dll",
        "Facepunch.Console.dll",
        "Facepunch.Network.dll",
        "Facepunch.Nexus.dll",
        "Facepunch.Ping.dll",
        "Facepunch.Unity.dll",
        "Facepunch.Rcon.dll",
        "Rust.Localization.dll",
        "Rust.Clans.Local.dll",
        "Rust.FileSystem.dll",
        "Rust.Harmony.dll",
        "Rust.Global.dll",
        "Rust.Data.dll",
        "Fleck.dll"
    ];

    private static readonly string[] OxideExcludedPrefixes =
    [
        "0Harmony",
        "System",
        "Microsoft",
        "mscorlib",
        "Unity",
        "Mono",
        "netstandard",
        "Oxide",
        "MySql.Data"
    ];

    private static readonly string[] CarbonMemberIgnores =
    [
        @"^HiddenValueBase$",
        @"^HiddenValue`1$",
        @"^Pool$"
    ];

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] is "--self-test" or "self-test")
            {
                SelfTest.Run();
                Console.WriteLine("RdPublicizer self-test passed.");
                return 0;
            }

            var options = CliOptions.Parse(args);
            PublicizeDirectory(options);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static void PublicizeDirectory(CliOptions options)
    {
        if (!Directory.Exists(options.Input))
        {
            throw new DirectoryNotFoundException($"Input directory '{options.Input}' was not found.");
        }

        Directory.CreateDirectory(options.Output);
        foreach (var existing in Directory.EnumerateFiles(options.Output, "*.dll", SearchOption.AllDirectories))
        {
            File.Delete(existing);
        }

        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(options.Input);
        var readerParameters = new ReaderParameters
        {
            AssemblyResolver = resolver,
            ReadWrite = false,
            InMemory = true
        };

        var written = 0;
        var skipped = 0;
        foreach (var path in Directory.EnumerateFiles(options.Input, "*.dll", SearchOption.TopDirectoryOnly).OrderBy(p => p, StringComparer.Ordinal))
        {
            var fileName = Path.GetFileName(path);
            if (!ShouldProcess(options.Mode, fileName))
            {
                continue;
            }

            try
            {
                using var assembly = AssemblyDefinition.ReadAssembly(path, readerParameters);
                if (options.Mode == PublicizerMode.Carbon)
                {
                    CarbonPublicizer.Publicize(assembly);
                }
                else
                {
                    OxidePublicizer.Publicize(assembly);
                }

                var destination = Path.Combine(options.Output, fileName);
                assembly.Write(destination);
                written++;
                Console.WriteLine($"Publicized {fileName} ({options.Mode})");
            }
            catch (Exception ex) when (IsNonManagedAssemblyException(ex))
            {
                // Native or otherwise non-managed DLLs land in the flat overlay; skip them.
                // Write to stdout so PowerShell $ErrorActionPreference Stop does not abort
                // the caller and leave publicized assemblies un-overlaid.
                skipped++;
                Console.WriteLine($"Skipping {fileName}: not a managed assembly");
            }
        }

        if (written == 0)
        {
            throw new InvalidOperationException($"No assemblies were selected for {options.Mode} publicizing under '{options.Input}'.");
        }

        if (skipped > 0)
        {
            Console.WriteLine($"Skipped {skipped} non-managed DLL(s) during {options.Mode} publicizing.");
        }
    }

    private static bool IsNonManagedAssemblyException(Exception ex)
    {
        for (var current = ex; current is not null; current = current.InnerException)
        {
            if (current is BadImageFormatException)
            {
                return true;
            }

            if (current.Message.Contains("Format of the executable", StringComparison.OrdinalIgnoreCase) ||
                current.Message.Contains("not a valid CLR", StringComparison.OrdinalIgnoreCase) ||
                current.Message.Contains("Invalid PE", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool ShouldProcess(PublicizerMode mode, string fileName)
    {
        if (mode == PublicizerMode.Carbon)
        {
            return CarbonAssemblies.Any(prefix => fileName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
        }

        var name = Path.GetFileNameWithoutExtension(fileName);
        return !OxideExcludedPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }

    internal enum PublicizerMode
    {
        Oxide,
        Carbon
    }

    private sealed class CliOptions
    {
        public required PublicizerMode Mode { get; init; }
        public required string Input { get; init; }
        public required string Output { get; init; }

        public static CliOptions Parse(string[] args)
        {
            string? mode = null;
            string? input = null;
            string? output = null;
            for (var i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--mode":
                        mode = RequireValue(args, ref i, "--mode");
                        break;
                    case "--input":
                        input = RequireValue(args, ref i, "--input");
                        break;
                    case "--output":
                        output = RequireValue(args, ref i, "--output");
                        break;
                    default:
                        throw new ArgumentException($"Unknown argument '{args[i]}'. Expected --mode Oxide|Carbon --input <dir> --output <dir>.");
                }
            }

            if (string.IsNullOrWhiteSpace(mode) || string.IsNullOrWhiteSpace(input) || string.IsNullOrWhiteSpace(output))
            {
                throw new ArgumentException("Usage: RdPublicizer --mode Oxide|Carbon --input <rustManagedDir> --output <destDir>");
            }

            if (!Enum.TryParse<PublicizerMode>(mode, ignoreCase: true, out var parsedMode))
            {
                throw new ArgumentException($"Unsupported mode '{mode}'. Expected Oxide or Carbon.");
            }

            return new CliOptions
            {
                Mode = parsedMode,
                Input = Path.GetFullPath(input),
                Output = Path.GetFullPath(output)
            };
        }

        private static string RequireValue(string[] args, ref int index, string name)
        {
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException($"Missing value for {name}.");
            }

            index++;
            return args[index];
        }
    }

    internal static class CarbonPublicizer
    {
        private static readonly Regex[] IgnorePatterns = CarbonMemberIgnores
            .Select(pattern => new Regex(pattern, RegexOptions.CultureInvariant | RegexOptions.Compiled))
            .ToArray();

        public static void Publicize(AssemblyDefinition assembly)
        {
            foreach (var type in assembly.MainModule.Types)
            {
                Publicize(type);
            }
        }

        private static bool IsIgnored(string name) => IgnorePatterns.Any(pattern => pattern.IsMatch(name));

        private static void Publicize(TypeDefinition type)
        {
            if (IsIgnored(type.Name))
            {
                return;
            }

            if (type.IsNested)
            {
                type.IsNestedPublic = true;
            }
            else
            {
                type.IsPublic = true;
            }

            foreach (var method in type.Methods)
            {
                if (IsIgnored($"{type.Name}.{method.Name}"))
                {
                    continue;
                }

                method.IsPublic = true;
            }

            foreach (var field in type.Fields)
            {
                if (IsIgnored($"{type.Name}.{field.Name}"))
                {
                    continue;
                }

                if (type.Events.Any(ev => ev.Name == field.Name))
                {
                    continue;
                }

                var hasSerializeField = field.CustomAttributes.Any(attribute =>
                    attribute.AttributeType.FullName == "UnityEngine.SerializeField");
                if (!field.IsPublic && !hasSerializeField)
                {
                    field.IsNotSerialized = true;
                }

                field.IsPublic = true;
            }

            foreach (var property in type.Properties)
            {
                if (property.GetMethod is not null)
                {
                    property.GetMethod.IsPublic = true;
                }

                if (property.SetMethod is not null)
                {
                    property.SetMethod.IsPublic = true;
                }
            }

            foreach (var nested in type.NestedTypes)
            {
                Publicize(nested);
            }
        }
    }

    internal static class OxidePublicizer
    {
        public static void Publicize(AssemblyDefinition assembly)
        {
            foreach (var type in assembly.MainModule.Types)
            {
                PublicizeType(type);
            }
        }

        private static bool HasAttribute(IMemberDefinition member, string suffix) =>
            member.CustomAttributes.Any(attribute =>
                attribute.AttributeType.FullName.EndsWith(suffix, StringComparison.Ordinal) ||
                attribute.AttributeType.Name.EndsWith(suffix, StringComparison.Ordinal));

        private static bool CanPublicizeMember(IMemberDefinition member) =>
            !HasAttribute(member, "CompilerGeneratedAttribute") &&
            !HasAttribute(member, "ExtensionAttribute");

        private static void PublicizeType(TypeDefinition type)
        {
            if (!CanPublicizeMember(type))
            {
                foreach (var nested in type.NestedTypes)
                {
                    PublicizeType(nested);
                }

                return;
            }

            if (type.IsNested)
            {
                if (!type.IsNestedPublic)
                {
                    type.IsNestedPublic = true;
                }
            }
            else if (!type.IsPublic)
            {
                type.IsPublic = true;
            }

            foreach (var field in type.Fields)
            {
                if (!field.IsPublic && CanPublicizeMember(field))
                {
                    field.IsPublic = true;
                }
            }

            foreach (var method in type.Methods)
            {
                if (!method.IsPublic && CanPublicizeMember(method))
                {
                    method.IsPublic = true;
                }
            }

            foreach (var property in type.Properties)
            {
                if (property.GetMethod is not null && !property.GetMethod.IsPublic && CanPublicizeMember(property.GetMethod))
                {
                    property.GetMethod.IsPublic = true;
                }

                if (property.SetMethod is not null && !property.SetMethod.IsPublic && CanPublicizeMember(property.SetMethod))
                {
                    property.SetMethod.IsPublic = true;
                }
            }

            foreach (var nested in type.NestedTypes)
            {
                PublicizeType(nested);
            }
        }
    }

    private static class SelfTest
    {
        public static void Run()
        {
            var root = Directory.CreateTempSubdirectory("rd-publicizer-self-test-");
            try
            {
                var input = Path.Combine(root.FullName, "input");
                var carbonOut = Path.Combine(root.FullName, "carbon");
                var oxideOut = Path.Combine(root.FullName, "oxide");
                Directory.CreateDirectory(input);

                WriteFixtureAssembly(Path.Combine(input, "Assembly-CSharp.dll"));
                WriteFixtureAssembly(Path.Combine(input, "System.Private.Ignored.dll"), systemLike: true);
                File.WriteAllBytes(Path.Combine(input, "NativePlugin.dll"), "not a managed assembly"u8.ToArray());
                File.WriteAllBytes(Path.Combine(input, "msvcp140.dll"), "not a managed assembly"u8.ToArray());

                PublicizeDirectory(new CliOptions { Mode = PublicizerMode.Carbon, Input = input, Output = carbonOut });
                PublicizeDirectory(new CliOptions { Mode = PublicizerMode.Oxide, Input = input, Output = oxideOut });

                AssertCarbon(Path.Combine(carbonOut, "Assembly-CSharp.dll"));
                AssertOxide(Path.Combine(oxideOut, "Assembly-CSharp.dll"));
                if (File.Exists(Path.Combine(carbonOut, "System.Private.Ignored.dll")))
                {
                    throw new InvalidOperationException("Carbon mode should not publicize assemblies outside the allowlist.");
                }

                if (File.Exists(Path.Combine(oxideOut, "System.Private.Ignored.dll")))
                {
                    throw new InvalidOperationException("Oxide mode should skip System* assemblies.");
                }

                if (File.Exists(Path.Combine(oxideOut, "NativePlugin.dll")) ||
                    File.Exists(Path.Combine(oxideOut, "msvcp140.dll")))
                {
                    throw new InvalidOperationException("Oxide mode should skip non-managed DLLs instead of failing.");
                }
            }
            finally
            {
                root.Delete(true);
            }
        }

        private static void WriteFixtureAssembly(string path, bool systemLike = false)
        {
            var name = Path.GetFileNameWithoutExtension(path);
            var assembly = AssemblyDefinition.CreateAssembly(
                new AssemblyNameDefinition(name, new Version(1, 0, 0, 0)),
                name,
                ModuleKind.Dll);

            if (systemLike)
            {
                var marker = new TypeDefinition(string.Empty, "Marker", TypeAttributes.Public | TypeAttributes.BeforeFieldInit,
                    assembly.MainModule.TypeSystem.Object);
                assembly.MainModule.Types.Add(marker);
                assembly.Write(path);
                return;
            }

            var gameType = new TypeDefinition("Game", "Entity", TypeAttributes.NotPublic | TypeAttributes.BeforeFieldInit,
                assembly.MainModule.TypeSystem.Object);
            var privateField = new FieldDefinition("health", FieldAttributes.Private, assembly.MainModule.TypeSystem.Int32);
            gameType.Fields.Add(privateField);

            var eventField = new FieldDefinition("Damaged", FieldAttributes.Private, assembly.MainModule.TypeSystem.Object);
            gameType.Fields.Add(eventField);
            var damagedEvent = new EventDefinition("Damaged", EventAttributes.None, assembly.MainModule.TypeSystem.Object);
            gameType.Events.Add(damagedEvent);

            var poolType = new TypeDefinition("Game", "Pool", TypeAttributes.NotPublic | TypeAttributes.BeforeFieldInit,
                assembly.MainModule.TypeSystem.Object);
            var poolField = new FieldDefinition("buffer", FieldAttributes.Private, assembly.MainModule.TypeSystem.Object);
            poolType.Fields.Add(poolField);

            var generatedType = new TypeDefinition("Game", "Generated", TypeAttributes.NotPublic | TypeAttributes.BeforeFieldInit,
                assembly.MainModule.TypeSystem.Object);
            var compilerGenerated = new TypeReference(
                "System.Runtime.CompilerServices",
                "CompilerGeneratedAttribute",
                assembly.MainModule,
                assembly.MainModule.TypeSystem.CoreLibrary);
            var compilerGeneratedCtor = new MethodReference(".ctor", assembly.MainModule.TypeSystem.Void, compilerGenerated)
            {
                HasThis = true
            };
            generatedType.CustomAttributes.Add(new CustomAttribute(compilerGeneratedCtor));
            var generatedField = new FieldDefinition("value", FieldAttributes.Private, assembly.MainModule.TypeSystem.Int32);
            generatedField.CustomAttributes.Add(new CustomAttribute(compilerGeneratedCtor));
            generatedType.Fields.Add(generatedField);

            assembly.MainModule.Types.Add(gameType);
            assembly.MainModule.Types.Add(poolType);
            assembly.MainModule.Types.Add(generatedType);
            assembly.Write(path);
        }

        private static void AssertCarbon(string path)
        {
            using var assembly = AssemblyDefinition.ReadAssembly(path);
            var entity = assembly.MainModule.Types.Single(type => type.Name == "Entity");
            var health = entity.Fields.Single(field => field.Name == "health");
            var damaged = entity.Fields.Single(field => field.Name == "Damaged");
            if (!entity.IsPublic || !health.IsPublic || !health.IsNotSerialized)
            {
                throw new InvalidOperationException("Carbon mode should publicize Entity.health and mark it NotSerialized.");
            }

            if (damaged.IsPublic)
            {
                throw new InvalidOperationException("Carbon mode must leave event backing fields private.");
            }

            var pool = assembly.MainModule.Types.Single(type => type.Name == "Pool");
            if (pool.IsPublic || pool.Fields.Single().IsPublic)
            {
                throw new InvalidOperationException("Carbon mode must leave ignored Pool types private.");
            }
        }

        private static void AssertOxide(string path)
        {
            using var assembly = AssemblyDefinition.ReadAssembly(path);
            var entity = assembly.MainModule.Types.Single(type => type.Name == "Entity");
            var health = entity.Fields.Single(field => field.Name == "health");
            if (!entity.IsPublic || !health.IsPublic)
            {
                throw new InvalidOperationException("Oxide mode should publicize Entity and health.");
            }

            var generated = assembly.MainModule.Types.Single(type => type.Name == "Generated");
            var generatedField = generated.Fields.Single();
            if (generated.IsPublic || generatedField.IsPublic)
            {
                throw new InvalidOperationException("Oxide mode must skip compiler-generated members.");
            }
        }
    }
}

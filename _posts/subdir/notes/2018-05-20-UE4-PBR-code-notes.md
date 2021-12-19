---
title: UE4 PBR code-notes
---

# direction light
## [mobile]
- MobileGGX.ush
- MobileShadingModels.ush
- MobileBasePassPixelShader.usf

```
// Specular BRDF
half CalcSpecular(half Roughness, half NoH)
{
	return (Roughness*0.25 + 0.25) * GGX_Mobile(Roughness, NoH);
}
```

```
// Taken from https://gist.github.com/romainguy/a2e9208f14cae37c579448be99f78f25
// Modified by Epic Games, Inc. To account for premultiplied light color and code style rules.
half GGX_Mobile(half Roughness, float NoH)
{
    // Walter et al. 2007, "Microfacet Models for Refraction through Rough Surfaces"
	float OneMinusNoHSqr = 1.0 - NoH * NoH; 
	half a = Roughness * Roughness;
	half n = NoH * a;
	half p = a / (OneMinusNoHSqr + n * n);
	half d = p * p;
	// clamp to avoid overlfow in a bright env
	return min(d, 2048.0);
}
```

最小的roughness值设定
```
// The smallest normalized value that can be represented in IEEE 754 (FP16) is 2^-24 = 5.96e-8.
// The code will make the following computation involving roughness: 1.0 / Roughness^4.
// Therefore to prevent division by zero on devices that do not support denormals, Roughness^4
// must be >= 5.96e-8. We will clamp to 0.015625 because 0.015625^4 = 5.96e-8.
GBuffer.Roughness = max(0.015625, GetMaterialRoughness(PixelMaterialInputs));
```

## [pc]
```
FDirectLighting DefaultLitBxDF( FGBufferData GBuffer, half3 N, half3 V, half3 L, float Falloff, float NoL, FAreaLight AreaLight, FShadowTerms Shadow )
```

### diffuse项：
```
Diffuse  = AreaLight.FalloffColor * (Falloff * NoL) * Diffuse_Lambert( GBuffer.DiffuseColor );
```
### specular项：

```
Specular = AreaLight.FalloffColor * (Falloff * NoL) * SpecularGGX(GBuffer.Roughness, GBuffer.SpecularColor, Context, NoL, AreaLight);
```
SpecularGGX
```
float3 SpecularGGX( float Roughness, float3 SpecularColor, BxDFContext Context, float NoL, FAreaLight AreaLight )
{
	float a2 = Pow4( Roughness );
	float Energy = EnergyNormalization( a2, Context.VoH, AreaLight );
	
	// Generalized microfacet specular
	float D = D_GGX( a2, Context.NoH ) * Energy;
	float Vis = Vis_SmithJointApprox( a2, Context.NoV, NoL );
	float3 F = F_Schlick( SpecularColor, Context.VoH );

	return (D * Vis) * F;
}
```
最小的roughness值设定
[SceneView.cpp]
```
void FSceneView::SetupCommonViewUniformBufferParameters
	ViewUniformShaderParameters.MinRoughness = FMath::Clamp(CVarGlobalMinRoughnessOverride.GetValueOnRenderThread(), 0.02f, 1.0f);
```

[CapsuleLightIntegrate.ush]
```
FDirectLighting IntegrateBxDF( FGBufferData GBuffer, half3 N, half3 V, FCapsuleLight Capsule, FShadowTerms Shadow, bool bInverseSquared )
		GBuffer.Roughness = max( GBuffer.Roughness, View.MinRoughness );
```

# IBL

## [mobile]
Private/MobileBasePassPixelShader.usf
```
void GatherSpecularIBL(FMaterialPixelParameters MaterialParameters
    , TextureCube ReflectionCube
    , SamplerState ReflectionSampler
    , half Roughness
    , half IndirectIrradiance
    , half MaxValue
    , inout half4 ImageBasedReflections
#if HQ_REFLECTIONS
    , int ReflectionIndex
    , inout half3 ExtraIndirectSpecular
    , inout half2 CompositedAverageBrightness
#endif
)

half AbsoluteSpecularMip = ComputeReflectionCaptureMipFromRoughness(Roughness, ResolvedView.ReflectionCubemapMaxMip);
half4 SpecularIBLSample = ReflectionCube.SampleLevel(ReflectionSampler, ProjectedCaptureVector, AbsoluteSpecularMip);

SpecularIBL = RGBMDecode(SpecularIBLSample, MaxValue);
SpecularIBL = SpecularIBL * SpecularIBL; // Specular BRDF
```

## [pc]
- Private/ReflectionEnvironmentComposite.ush
- Private/ReflectionEnvironmentPixelShader.usf

**IBL高光**
IBL高光计算中分离和的第二部分：EnvBRDF( SpecularColor, GBuffer.Roughness, NoV )，根据roughness和dot(Normal, ViewDir)采样BRDF-LUT

```
CompositeReflectionCapturesAndSkylight

float3 ReflectionEnvironment(FGBufferData GBuffer, float AmbientOcclusion, float2 BufferUV, float2 ScreenPosition, float4 SvPosition, float3 BentNormal, float3 SpecularColor)

BRANCH
if( GBuffer.ShadingModelID == SHADINGMODELID_CLEAR_COAT)
{
	...
}
else
{
    Color.rgb *= EnvBRDF( SpecularColor, GBuffer.Roughness, NoV );
}
```

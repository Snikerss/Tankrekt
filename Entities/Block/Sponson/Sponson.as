#include "WeaponCommon.as";
#include "AccurateSoundPlay.as";
#include "ParticleSpark.as";

const f32 PROJECTILE_SPEED = 9.0f;
const f32 PROJECTILE_SPREAD = 1.15;
const int FIRE_RATE = 60;
const f32 PROJECTILE_RANGE = 260.0f;

const u8 MAX_AMMO = 15;
const u8 REFILL_AMOUNT = 1;
const u8 REFILL_SECONDS = 3;
const u8 REFILL_SECONDARY_CORE_SECONDS = 6;
const u8 REFILL_SECONDARY_CORE_AMOUNT = 1;

Random _shotspreadrandom(0x11598); //clientside

void onInit(CBlob@ this)
{
	this.Tag("solid");
	this.Tag("sponson");
	this.Tag("weapon");
	this.Tag("usesAmmo");
	
	this.Tag("noEnemyEntry");
	this.set_string("seat label", "Get In Sponson");
	this.set_u8("seat icon", 7);
	
	this.set_f32("weight", 3.5f);
	
	this.addCommandID("fire");
	this.addCommandID("rotate");
	this.addCommandID("RecieveFireCMD");

	if (isServer())
	{
		this.set_u16("ammo", MAX_AMMO);
		this.set_u16("maxAmmo", MAX_AMMO);
		this.Sync("ammo", true);
		this.Sync("maxAmmo", true);
	}

	this.set_u32("fire time", 0);
	this.set_u16("parentID", 0);
	this.set_u16("childID", 0);

	CSprite@ sprite = this.getSprite();
    CSpriteLayer@ layer = sprite.addSpriteLayer("weapon", "Sponson_barrel.png", 16, 6);
    if (layer !is null)
    {
    	layer.SetRelativeZ(-2);
		layer.SetOffset(Vec2f(-4, 0));
    	layer.SetLighting(false);
     	Animation@ anim = layer.addAnimation("fire", 15, false);
        anim.AddFrame(1);
        anim.AddFrame(0);
        layer.SetAnimation("fire");
    }
}

void onTick(CBlob@ this)
{
	const int col = this.getShape().getVars().customData;
	if (col <= 0) return; //not placed yet

	const u32 gameTime = getGameTime();
	
	//fire ready
	const u32 fireTime = this.get_u32("fire time");
	this.set_bool("fire ready", (gameTime > fireTime + FIRE_RATE));
	
	AttachmentPoint@ seat = this.getAttachmentPoint(0);
	CBlob@ occupier = seat.getOccupied();
	if (occupier !is null)
	{
		Manual(this, occupier);
	}

	if (isServer())
	{
		Ship@ ship = getShipSet().getShip(col);
		if (ship !is null)
			refillAmmo(this, ship, REFILL_AMOUNT, REFILL_SECONDS, REFILL_SECONDARY_CORE_AMOUNT, REFILL_SECONDARY_CORE_SECONDS);
	}
}

void Manual(CBlob@ this, CBlob@ controller)
{
	Vec2f aimpos = controller.getAimPos();
	Vec2f pos = this.getPosition();
	Vec2f aimVec = aimpos - pos;

	// fire
	if (controller.isMyPlayer() && controller.isKeyPressed(key_action1) && canShoot(this) && isClearShot(this, aimVec))
	{
		Fire(this, aimVec, controller.getNetworkID());
	}

	// rotate turret
	Rotate(this, aimVec);
	aimVec.y *= -1;
	controller.setAngleDegrees(aimVec.Angle());
}

bool canShoot(CBlob@ this)
{
	return this.get_u32("fire time") + FIRE_RATE < getGameTime();
}

const bool isClearShot(CBlob@ this, Vec2f&in aimVec, const bool&in targetMerged = false)
{
	Vec2f pos = this.getPosition();
	const f32 distanceToTarget = Maths::Max(aimVec.Length(), 80.0f);
	CMap@ map = getMap();

	Vec2f offset = aimVec;
	offset.Normalize();
	offset *= 7.0f;

	HitInfo@[] hitInfos;
	map.getHitInfosFromRay(pos + offset.RotateBy(30), -aimVec.Angle(), distanceToTarget, this, @hitInfos);
	map.getHitInfosFromRay(pos + offset.RotateBy(-60), -aimVec.Angle(), distanceToTarget, this, @hitInfos);
	
	const u8 hitLength = hitInfos.length;
	if (hitLength > 0)
	{
		//HitInfo objects are sorted, first come closest hits
		for (u8 i = 0; i < hitLength; i++)
		{
			HitInfo@ hi = hitInfos[i];
			CBlob@ b = hi.blob;
			if (b is null || b is this) continue;

			const int thisColor = this.getShape().getVars().customData;
			const int bColor = b.getShape().getVars().customData;
			
			const bool sameShip = bColor != 0 && thisColor == bColor;
			const bool canShootSelf = targetMerged && hi.distance > distanceToTarget * 0.7f;

			if (b.hasTag("block") && b.getShape().getVars().customData > 0 && ((b.hasTag("solid") && !b.hasTag("plank")) || b.hasTag("weapon")) && sameShip && !canShootSelf)
			{
				return false;
			}
		}
	}
	
	//check to make sure we aren't shooting through rock
	Vec2f solidPos;
	if (map.rayCastSolid(pos, pos + aimVec, solidPos))
	{
		AttachmentPoint@ seat = this.getAttachmentPoint(0);
		CBlob@ occupier = seat.getOccupied();

		if (occupier is null) return false;
	}

	return true;
}

void Fire(CBlob@ this, Vec2f&in aimVector, const u16&in netid)
{
	const f32 aimdist = Maths::Min(aimVector.Normalize(), PROJECTILE_RANGE);

	Vec2f offset(_shotspreadrandom.NextFloat() * PROJECTILE_SPREAD, 0);
	offset.RotateBy(_shotspreadrandom.NextFloat() * 360.0f, Vec2f());

	const Vec2f _vel = (aimVector * PROJECTILE_SPEED) + offset;
	const f32 _lifetime = Maths::Max(0.05f + aimdist/PROJECTILE_SPEED/32.0f, 0.25f);

	CBitStream params;
	params.write_netid(netid);
	params.write_Vec2f(_vel);
	params.write_f32(_lifetime);
	this.SendCommand(this.getCommandID("fire"), params);
	this.set_u32("fire time", getGameTime());
}

void Rotate(CBlob@ this, Vec2f&in aimVector)
{
	CSpriteLayer@ layer = this.getSprite().getSpriteLayer("weapon");
	if (layer !is null)
	{
		layer.ResetTransform();
		layer.SetOffset(Vec2f(-4, 0));
		layer.RotateBy(-aimVector.getAngleDegrees() - this.getAngleDegrees(), Vec2f(4, 0));
	}
}

void onCommand(CBlob@ this, u8 cmd, CBitStream@ params)
{
    if (cmd == this.getCommandID("fire"))
    {
		CBlob@ caller = getBlobByNetworkID(params.read_netid());
		Vec2f pos = this.getPosition();

		//ammo
		u16 ammo = this.get_u16("ammo");

		if (ammo == 0)
		{
			directionalSoundPlay("LoadingTick1", pos, 1.0f);
			return;
		}

		ammo--;
		this.set_u16("ammo", ammo);

		Vec2f velocity = params.read_Vec2f();
		Vec2f aimVector = velocity;		aimVector.Normalize();
		const f32 time = params.read_f32();

		if (isServer())
		{
            CBlob@ bullet = server_CreateBlob("flakbullet", this.getTeamNum(), pos + aimVector*9);
            if (bullet !is null)
            {
            	if (caller !is null)
				{
					if (caller.getPlayer() !is null)
						bullet.SetDamageOwnerPlayer(caller.getPlayer());
				}

                bullet.setVelocity(velocity);
                bullet.server_SetTimeToDie(time);
				bullet.setAngleDegrees(-aimVector.Angle());
            }
    	}

		if (isClient())
		{
			Rotate(this, aimVector);
			shotParticles(pos + aimVector*9, velocity.Angle());
			directionalSoundPlay("FlakFire.ogg", pos, 0.50f);

			CSpriteLayer@ layer = this.getSprite().getSpriteLayer("weapon");
			if (layer !is null)
				layer.animation.SetFrameIndex(0);
		}
    }
	else if(cmd == this.getCommandID("rotate"))
	{
		if(isClient())
		{
			Vec2f aimVector = params.read_Vec2f();
			CSpriteLayer@ layer = this.getSprite().getSpriteLayer("weapon");
			if (layer !is null)
			{
				layer.ResetTransform();
				layer.SetOffset(Vec2f(-4, 0));
				layer.RotateBy(-aimVector.getAngleDegrees() - this.getAngleDegrees(), Vec2f(4, 0));
			}
		}
	}
	else if(cmd == this.getCommandID("RecieveFireCMD"))
	{
		Vec2f aimVector = params.read_Vec2f();
		const f32 aimdist = Maths::Min(aimVector.Normalize(), PROJECTILE_RANGE);

		Vec2f offset(_shotspreadrandom.NextFloat() * PROJECTILE_SPREAD, 0);
		offset.RotateBy(_shotspreadrandom.NextFloat() * 360.0f, Vec2f());

		const Vec2f _vel = (aimVector * PROJECTILE_SPEED) + offset;
		const f32 _lifetime = Maths::Max(0.05f + aimdist/PROJECTILE_SPEED/32.0f, 0.25f);

		if (isServer())
		{
			if(canShoot(this))
			{
				CBitStream bs;
				bs.write_netid(params.read_netid());
				bs.write_Vec2f(_vel);
				bs.write_f32(_lifetime);
				this.SendCommand(this.getCommandID("fire"), bs);
				this.set_u32("fire time", getGameTime());
			}
		}
	}
}

!> @file solver.f90
!!
!! Single iteration of the governing equations.
!
! *****************************************************************************
!
!  (c) J. Blazek, CFD Consulting & Analysis, www.cfd-ca.de
!  Created February 25, 2014
!  Last modification: September 19, 2014
!
! *****************************************************************************
!
!  This program is free software; you can redistribute it and/or
!  modify it under the terms of the GNU General Public License
!  as published by the Free Software Foundation; either version 2
!  of the License, or (at your option) any later version.
!
!  This program is distributed in the hope that it will be useful,
!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
!  GNU General Public License for more details.
!
!  You should have received a copy of the GNU General Public License
!  along with this program; if not, write to the Free Software
!  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
!
! *****************************************************************************

!> Integrates the four basic equations (continuity, momentum and energy) by
!! the explicit, multi-stage (Runge-Kutta) time-stepping scheme.
!!
!! @param iwork  integer work space for temporary variables
!! @param work   real work space for temporary variables
!!
subroutine Solver( iwork,work )

  use ModDataTypes
  use ModGeometry
  use ModNumerics
  use ModPhysics
  use ModInterfaces, only : BoundaryConditions, CompTheta, Cons2Prim, &
                            DependentVarsAll, DissipRoe1, DissipRoe1Prec, &
                            DissipRoe2, DissipRoe2Prec, ErrorMessage, &
                            FluxRoe1, FluxRoe2, FluxViscous, Gradients, &
                            GradientsVisc, Irsmoo, Limiter, LimiterInit, &
                            MatrixTimesInverse, Periodic, Prim2Cons, &
                            TimeStep, ZeroResiduals
  implicit none

! parameters
  integer     :: iwork(:)
  real(rtype) :: work(:)

! local variables
  integer     :: i, irk, mp, mp2
  real(rtype) :: blend1, fac, adtv, H, q2, rhop, rhoT, hT, theta, u, v
  real(rtype) :: wvec(5), wpvec(5), pmat(5,5), gmat1(5,5), dmat(5,5), r(5)
  real(rtype), allocatable :: dum1(:,:), dum2(:,:)

! *****************************************************************************
! calculate dimensions for dummy arrays (LimiterInit, Limiter, FluxRoe,
! Irsmoo, BoundaryConditions); check them

  mp  = nconv*nnodes
  mp2 = 2*mp
  if (mp2 > Ubound(work,1)) then
    call ErrorMessage( "insufficient work space in Solver" )
  endif

! store previous solution; set dissipation = 0

  cvold(:,:) = cv(:,:)
  diss(:,:)  = 0.D0

! compute the time step

  call TimeStep

! loop over the Runge-Kutta stages ============================================

  do irk=1,nrk

! - initialize dissipation

    if (irk>1 .and. ldiss(irk)/=0) then
      blend1 = 1.D0 - betrk(irk)
      do i=1,nnodes
        diss(1,i) = blend1*diss(1,i)
        diss(2,i) = blend1*diss(2,i)
        diss(3,i) = blend1*diss(3,i)
        diss(4,i) = blend1*diss(4,i)
      enddo
    endif

! - viscous flux (Navier-Stokes eqs.)

    if (ldiss(irk)/=0 .and. kequs=="N") then
      call GradientsVisc
      call FluxViscous( betrk(irk) )
    endif

! - Roe's flux-difference splitting scheme (upwind)

    ! limiter and upwind dissipation
    if (ldiss(irk) /= 0) then
      if (iorder < 2) then
        if (kprecond == "Y") then
          call DissipRoe1Prec( betrk(irk) )
        else
          call DissipRoe1( betrk(irk) )
        endif
      else
	    allocate(dum1(4,nnodes)) ! Truong ajoute 27/05/2017
		allocate(dum2(4,nnodes)) ! Truong ajoute 27/05/2017
        dum1 = Reshape( work(1:mp)      ,(/4, nnodes/) )
        dum2 = Reshape( work((mp+1):mp2),(/4, nnodes/) )
        if (kequs == "E") call Gradients
        call LimiterInit( dum1,dum2 )
        call Limiter( dum1,dum2 )
        if (kprecond == "Y") then
          call DissipRoe2Prec( betrk(irk) )
        else
          call DissipRoe2( betrk(irk) )
        endif

		if (allocated(dum1)) deallocate(dum1) ! Truong ajoute 27/05/2017
		if (allocated(dum2)) deallocate(dum2) ! Truong ajoute 27/05/2017
      endif
    endif

    ! convective flux; add upwind dissipation => residual
    if (iorder < 2) then
      call FluxRoe1
    else
      call FluxRoe2
    endif

! - preconditioning

    if (kprecond == "Y") then
      do i=1,nndint
        rhop  =  cv(1,i)/dv(1,i)
        rhoT  = -cv(1,i)/dv(2,i)
        hT    = dv(5,i)
        u     = cv(2,i)/cv(1,i)
        v     = cv(3,i)/cv(1,i)
        q2    = u*u + v*v
        H     = (cv(4,i)+dv(1,i))/cv(1,i)
        theta = CompTheta( dv(4,i),dv(3,i),q2 )

        wvec(1)  = cv(1,i)
        wvec(2)  = cv(2,i)
        wvec(3)  = cv(3,i)
        wvec(4)  = 0.D0
        wvec(5)  = cv(4,i)
        wpvec(1) = dv(1,i)
        wpvec(2) = u
        wpvec(3) = v
        wpvec(4) = 0.D0
        wpvec(5) = dv(2,i)

        call Cons2Prim( wvec,wpvec,H,q2,theta,rhoT,0.D0,hT,gmat1 )
        call Prim2Cons( wvec,wpvec,H,rhop,rhoT,0.D0,hT,pmat )
        call MatrixTimesInverse( wpvec,q2,pmat,gmat1,dmat )
        r(1)     = rhs(1,i)
        r(2)     = rhs(2,i)
        r(3)     = rhs(3,i)
        r(4)     = rhs(4,i)
        rhs(1,i) = dmat(1,1)*r(1) + dmat(1,2)*r(2) + &
                   dmat(1,3)*r(3) + dmat(1,5)*r(4)
        rhs(2,i) = dmat(2,1)*r(1) + dmat(2,2)*r(2) + &
                   dmat(2,3)*r(3) + dmat(2,5)*r(4)
        rhs(3,i) = dmat(3,1)*r(1) + dmat(3,2)*r(2) + &
                   dmat(3,3)*r(3) + dmat(3,5)*r(4)
        rhs(4,i) = dmat(5,1)*r(1) + dmat(5,2)*r(2) + &
                   dmat(5,3)*r(3) + dmat(5,5)*r(4)
      enddo
    endif

! - correct residuals at symmetry/no-slip boundaries

    call ZeroResiduals

! - combine residuals at periodic boundaries

    call Periodic( rhs )

! - residual * time step / volume

    fac = ark(irk)*cfl
    do i=1,nndint
      adtv     = fac*tstep(i)/vol(i)
      rhs(1,i) = adtv*rhs(1,i)
      rhs(2,i) = adtv*rhs(2,i)
      rhs(3,i) = adtv*rhs(3,i)
      rhs(4,i) = adtv*rhs(4,i)
    enddo

! - implicit residual smoothing

    if (epsirs > 0.D0) then
	  allocate(dum1(4,nnodes)) ! Truong ajoute 27/05/2017
	  allocate(dum2(4,nnodes)) ! Truong ajoute 27/05/2017
      dum1 = Reshape( work(1:mp)      ,(/4, nnodes/) )
      dum2 = Reshape( work((mp+1):mp2),(/4, nnodes/) )
      call Irsmoo( iwork,dum1,dum2 )
      call ZeroResiduals

	  if (allocated(dum1)) deallocate(dum1) ! Truong ajoute 27/05/2017
	  if (allocated(dum2)) deallocate(dum2) ! Truong ajoute 27/05/2017
    endif

! - update - new solution, new dependent variables

    do i=1,nndint
      cv(1,i) = cvold(1,i) - rhs(1,i)
      cv(2,i) = cvold(2,i) - rhs(2,i)
      cv(3,i) = cvold(3,i) - rhs(3,i)
      cv(4,i) = cvold(4,i) - rhs(4,i)
    enddo

    call DependentVarsAll

! - boundary conditions

    call BoundaryConditions( work )

  enddo ! irk

end subroutine Solver
